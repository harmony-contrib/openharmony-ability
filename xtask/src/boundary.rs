use crate::Result;
use quote::ToTokens;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, fs, path::Path, process::Command};
use syn::visit::{self, Visit};

const BASELINE: &str = "docs/native-boundary-baseline.json";

#[derive(Deserialize)]
struct Metadata {
    packages: Vec<Package>,
}

#[derive(Deserialize)]
struct Package {
    manifest_path: String,
    dependencies: Vec<Dependency>,
    features: BTreeMap<String, Vec<String>>,
}

#[derive(Deserialize, Serialize)]
struct Dependency {
    name: String,
    #[serde(default)]
    rename: Option<String>,
    #[serde(default)]
    req: String,
    #[serde(default)]
    target: Option<String>,
    #[serde(default)]
    kind: Option<String>,
    features: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
struct Violation {
    path: String,
    kind: String,
    identity: String,
}

#[derive(Deserialize)]
struct FrozenBaseline {
    source_commit: String,
    violations: Vec<FrozenViolation>,
}

#[derive(Deserialize)]
struct FrozenViolation {
    #[serde(flatten)]
    violation: Violation,
    count: usize,
    recommendation: String,
}

fn dynamic_feature(feature: &str) -> bool {
    feature.rsplit('/').next() == Some("dyn-symbols")
}

fn dependency_kind(name: &str) -> Option<&'static str> {
    if name == "napi-sys-ohos" {
        Some("napi-transport-sys-dependency")
    } else if name == "libloading" || name.split('-').any(|part| part == "sys") {
        Some("native-sys-or-loader-dependency")
    } else {
        None
    }
}

fn finding(path: &str, kind: &str, identity: String) -> Violation {
    Violation {
        path: path.into(),
        kind: kind.into(),
        identity,
    }
}

fn dependency_errors(metadata: &Metadata, root: &Path) -> Result<Vec<Violation>> {
    let mut errors = Vec::new();
    for package in &metadata.packages {
        let path = Path::new(&package.manifest_path)
            .strip_prefix(root)?
            .to_str()
            .ok_or("Non-UTF-8 manifest path")?;
        for dependency in &package.dependencies {
            if let Some(kind) = dependency_kind(&dependency.name) {
                errors.push(finding(path, kind, serde_json::to_string(dependency)?));
            }
            if dependency
                .features
                .iter()
                .any(|feature| dynamic_feature(feature))
            {
                errors.push(finding(
                    path,
                    "dynamic-symbol-feature",
                    serde_json::to_string(dependency)?,
                ));
            }
        }
        for (name, features) in &package.features {
            for feature in features.iter().filter(|feature| dynamic_feature(feature)) {
                errors.push(finding(
                    path,
                    "dynamic-symbol-feature",
                    format!("{name} = {feature}"),
                ));
            }
        }
    }
    Ok(errors)
}

fn workspace_errors(source: &str) -> Result<Vec<Violation>> {
    let document: toml::Value = toml::from_str(source)?;
    let mut errors = Vec::new();
    if let Some(dependencies) = document
        .get("workspace")
        .and_then(|workspace| workspace.get("dependencies"))
        .and_then(toml::Value::as_table)
    {
        for (alias, dependency) in dependencies {
            let name = dependency
                .get("package")
                .and_then(toml::Value::as_str)
                .unwrap_or(alias);
            if let Some(kind) = dependency_kind(name) {
                errors.push(finding(
                    "Cargo.toml",
                    kind,
                    format!("{alias} = {dependency}"),
                ));
            }
            if let Some(features) = dependency.get("features").and_then(toml::Value::as_array) {
                for feature in features
                    .iter()
                    .filter_map(toml::Value::as_str)
                    .filter(|feature| dynamic_feature(feature))
                {
                    errors.push(finding(
                        "Cargo.toml",
                        "dynamic-symbol-feature",
                        format!("{alias} = {feature}"),
                    ));
                }
            }
        }
    }
    Ok(errors)
}

#[derive(Default)]
struct NativeImports {
    errors: Vec<(String, String)>,
}

impl NativeImports {
    fn record(&mut self, kind: &str, item: &impl ToTokens) {
        self.errors
            .push((kind.into(), item.to_token_stream().to_string()));
    }

    fn import(&mut self, name: &str, item: &impl ToTokens) {
        if name == "libloading" {
            self.record("runtime-library-loader", item);
        }
        if name.ends_with("_sys") || name.contains("_sys_") {
            self.record(
                if name == "napi_sys_ohos" {
                    "napi-transport-sys-import"
                } else {
                    "native-sys-import"
                },
                item,
            );
        }
    }
}

impl<'ast> Visit<'ast> for NativeImports {
    fn visit_item_extern_crate(&mut self, item: &'ast syn::ItemExternCrate) {
        self.import(&item.ident.to_string(), item);
    }

    fn visit_item_foreign_mod(&mut self, item: &'ast syn::ItemForeignMod) {
        for declaration in &item.items {
            self.record("local-ffi-import", declaration);
        }
    }

    fn visit_path(&mut self, path: &'ast syn::Path) {
        for segment in &path.segments {
            self.import(&segment.ident.to_string(), path);
        }
        visit::visit_path(self, path);
    }

    fn visit_item_use(&mut self, item: &'ast syn::ItemUse) {
        struct Names(Vec<String>);
        impl<'ast> Visit<'ast> for Names {
            fn visit_ident(&mut self, ident: &'ast syn::Ident) {
                self.0.push(ident.to_string());
            }
        }
        let mut names = Names(Vec::new());
        names.visit_use_tree(&item.tree);
        for name in names.0 {
            self.import(&name, item);
        }
    }

    fn visit_expr_call(&mut self, call: &'ast syn::ExprCall) {
        if let syn::Expr::Path(path) = call.func.as_ref() {
            if let Some(segment) = path.path.segments.last() {
                let name = segment.ident.to_string();
                if [
                    "dlopen",
                    "dlsym",
                    "dlmopen",
                    "LoadLibrary",
                    "LoadLibraryA",
                    "LoadLibraryW",
                    "GetProcAddress",
                ]
                .contains(&name.as_str())
                {
                    self.record("runtime-symbol-probe", call);
                }
                if ["OH_", "OHOS_"]
                    .iter()
                    .any(|prefix| name.starts_with(prefix))
                {
                    self.record("raw-native-call", call);
                } else if name.starts_with("napi_") {
                    self.record("raw-napi-transport-call", call);
                }
            }
        }
        visit::visit_expr_call(self, call);
    }
}

fn counts(violations: Vec<Violation>) -> BTreeMap<Violation, usize> {
    let mut counts = BTreeMap::new();
    for violation in violations {
        *counts.entry(violation).or_default() += 1;
    }
    counts
}

fn ratchet(
    actual: &BTreeMap<Violation, usize>,
    baseline: Option<&FrozenBaseline>,
) -> Result<usize> {
    let mut frozen = BTreeMap::new();
    if let Some(baseline) = baseline {
        if baseline.source_commit.len() != 40
            || !baseline
                .source_commit
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit())
        {
            return Err("Native boundary baseline must name its frozen source commit".into());
        }
        for entry in &baseline.violations {
            let path = Path::new(&entry.violation.path);
            if path.is_absolute()
                || path
                    .components()
                    .any(|component| !matches!(component, std::path::Component::Normal(_)))
                || entry.violation.identity.is_empty()
                || entry.recommendation.trim().is_empty()
                || entry.count == 0
                || frozen
                    .insert(entry.violation.clone(), entry.count)
                    .is_some()
            {
                return Err("Invalid or duplicate exact native boundary baseline entry".into());
            }
        }
    }
    let mut errors = Vec::new();
    let mut inherited = 0;
    for (violation, allowed) in &frozen {
        let count = actual.get(violation).copied().unwrap_or_default();
        if count < *allowed {
            errors.push(format!(
                "{}: stale frozen baseline entry {}: {} (actual {count}, frozen {allowed}); remove or shrink the resolved entry",
                violation.path, violation.kind, violation.identity
            ));
        }
    }
    for (violation, count) in actual {
        let allowed = frozen.get(violation).copied().unwrap_or_default();
        if *count > allowed {
            errors.push(format!(
                "{}: {}: {} ({} occurrence(s), frozen allowance {allowed})",
                violation.path, violation.kind, violation.identity, count
            ));
        }
        inherited += count.min(&allowed);
    }
    if !errors.is_empty() {
        return Err(errors.join("\n").into());
    }
    Ok(inherited)
}

pub fn run(root: &Path) -> Result<()> {
    let output = Command::new("cargo")
        .args(["metadata", "--locked", "--no-deps", "--format-version", "1"])
        .current_dir(root)
        .output()?;
    if !output.status.success() {
        return Err(String::from_utf8(output.stderr)?.into());
    }
    let metadata: Metadata = serde_json::from_slice(&output.stdout)?;
    let mut errors = dependency_errors(&metadata, root)?;
    errors.extend(workspace_errors(&fs::read_to_string(
        root.join("Cargo.toml"),
    )?)?);
    for directory in ["crates", "rust_example", "xtask"] {
        for file in crate::rust_files(&root.join(directory))? {
            let source = file
                .strip_prefix(root)?
                .to_str()
                .ok_or("Non-UTF-8 source path")?;
            let syntax = syn::parse_file(&fs::read_to_string(&file)?)
                .map_err(|error| format!("{source}: {error}"))?;
            let mut visitor = NativeImports::default();
            visitor.visit_file(&syntax);
            errors.extend(
                visitor
                    .errors
                    .into_iter()
                    .map(|(kind, identity)| finding(source, &kind, identity)),
            );
        }
    }
    let baseline_path = root.join(BASELINE);
    let baseline = if baseline_path.exists() {
        Some(serde_json::from_str::<FrozenBaseline>(
            &fs::read_to_string(baseline_path)?,
        )?)
    } else {
        None
    };
    let inherited = ratchet(&counts(errors), baseline.as_ref())?;
    println!("Native boundary passed: {} workspace packages; no new native boundary violations; {inherited} frozen main-baseline occurrence(s) remain (not resolved).", metadata.packages.len());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checks_package_names_not_aliases_and_includes_target_and_workspace_dependencies() {
        let metadata = serde_json::from_str(r#"{"packages":[{
            "manifest_path":"/repo/crates/plugin/Cargo.toml",
            "dependencies":[
                {"name":"native-sys","rename":"safe","target":"cfg(target_env = \"ohos\")","features":[]},
                {"name":"napi-ohos","features":["dyn-symbols"]}
            ],
            "features":{"dynamic":["napi-ohos?/dyn-symbols"]}
        }]}"#).unwrap();
        assert_eq!(
            dependency_errors(&metadata, Path::new("/repo"))
                .unwrap()
                .len(),
            3
        );
        let source = r#"[workspace.dependencies]
            safe = { package = "native-sys", version = "1" }
            napi = { package = "napi-sys-ohos", version = "1" }
            bridge = { version = "1", features = ["dyn-symbols"] }
        "#;
        let violations = workspace_errors(source).unwrap();
        assert_eq!(violations.len(), 3);
        assert_eq!(violations[1].kind, "napi-transport-sys-dependency");
    }

    fn source_errors(source: &str) -> Vec<Violation> {
        let mut visitor = NativeImports::default();
        visitor.visit_file(&syn::parse_file(source).unwrap());
        visitor
            .errors
            .into_iter()
            .map(|(kind, identity)| finding("src/legacy.rs", &kind, identity))
            .collect()
    }

    #[test]
    fn parses_real_imports_and_calls_not_comments_or_strings() {
        assert!(source_errors(
            r#"
            // use libloading::Library;
            const MESSAGE: &str = "OH_RawCall(); dlopen(); extern C {}";
            fn safe() {}
        "#
        )
        .is_empty());
        for source in [
            "use native_sys as renamed;",
            "extern crate native_sys as renamed;",
            "use libloading::{Library};",
            "unsafe extern \"C\" { fn foreign(); }",
            "fn raw() { native::OH_RawCall(); }",
            "fn dynamic() { dlsym(); }",
        ] {
            assert!(!source_errors(source).is_empty(), "{source}");
        }
        assert!(source_errors(
            "use napi_ohos::sys::{napi_env, napi_value}; struct Transport(napi_env, napi_value);"
        )
        .is_empty());
        assert_eq!(
            source_errors("use napi_sys_ohos::napi_env;")[0].kind,
            "napi-transport-sys-import"
        );
    }

    fn baseline(violations: Vec<Violation>) -> FrozenBaseline {
        FrozenBaseline {
            source_commit: "35dda6f6cc8eef55f4da5142acee1ebb791a7d52".into(),
            violations: counts(violations)
                .into_iter()
                .map(|(violation, count)| FrozenViolation {
                    violation,
                    count,
                    recommendation: "fixture: existing main recommendation".into(),
                })
                .collect(),
        }
    }

    #[test]
    fn exact_frozen_baseline_rejects_new_raw_calls_in_the_same_file_and_extra_occurrences() {
        let inherited = source_errors("fn legacy() { OH_LegacyCall(1); }");
        let baseline = baseline(inherited.clone());
        assert_eq!(
            ratchet(&counts(inherited.clone()), Some(&baseline)).unwrap(),
            1
        );
        for changed in [
            "fn legacy() { OH_LegacyCall(1); OH_NewCall(); }",
            "fn legacy() { OH_LegacyCall(1); OH_LegacyCall(1); }",
            "fn legacy() { OH_LegacyCall(2); }",
        ] {
            assert!(ratchet(&counts(source_errors(changed)), Some(&baseline)).is_err());
        }
        let mut moved = inherited;
        moved[0].path = "src/new.rs".into();
        assert!(ratchet(&counts(moved), Some(&baseline)).is_err());
    }

    #[test]
    fn exact_frozen_baseline_rejects_new_sys_dependencies_and_stale_entries() {
        let source = r#"[workspace.dependencies]
            legacy = { package = "native-sys", version = "1" }
        "#;
        let inherited = workspace_errors(source).unwrap();
        let baseline = baseline(inherited.clone());
        assert!(ratchet(&counts(inherited), Some(&baseline)).is_ok());
        let changed = format!("{source}\nnew = {{ package = \"new-sys\", version = \"1\" }}");
        assert!(ratchet(
            &counts(workspace_errors(&changed).unwrap()),
            Some(&baseline)
        )
        .is_err());
        assert!(ratchet(&BTreeMap::new(), Some(&baseline)).is_err());
        assert_eq!(ratchet(&BTreeMap::new(), None).unwrap(), 0);
    }

    #[test]
    fn rejects_baseline_entries_without_recommendation_traceability() {
        let inherited = source_errors("fn legacy() { OH_LegacyCall(1); }");
        let mut baseline = baseline(inherited.clone());
        baseline.violations[0].recommendation.clear();
        assert!(ratchet(&counts(inherited), Some(&baseline)).is_err());
    }
}
