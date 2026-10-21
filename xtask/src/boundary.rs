use crate::Result;
use serde::Deserialize;
use std::{fs, path::Path, process::Command};
use syn::visit::{self, Visit};

#[derive(Deserialize)]
struct Metadata {
    packages: Vec<Package>,
}

#[derive(Deserialize)]
struct Package {
    manifest_path: String,
    dependencies: Vec<Dependency>,
    features: std::collections::BTreeMap<String, Vec<String>>,
}

#[derive(Deserialize)]
struct Dependency {
    name: String,
    features: Vec<String>,
}

fn dynamic_feature(feature: &str) -> bool {
    feature.rsplit('/').next() == Some("dyn-symbols")
}

fn dependency_errors(metadata: &Metadata) -> Vec<String> {
    let mut errors = Vec::new();
    for package in &metadata.packages {
        for dependency in &package.dependencies {
            if dependency.name == "libloading"
                || dependency.name.split('-').any(|part| part == "sys")
            {
                errors.push(format!(
                    "{}: forbidden direct dependency {}",
                    package.manifest_path, dependency.name
                ));
            }
            if dependency
                .features
                .iter()
                .any(|feature| dynamic_feature(feature))
            {
                errors.push(format!(
                    "{}: runtime symbol loading enabled on {}",
                    package.manifest_path, dependency.name
                ));
            }
        }
        for (name, features) in &package.features {
            if features.iter().any(|feature| dynamic_feature(feature)) {
                errors.push(format!(
                    "{}: feature {name} enables runtime symbol loading",
                    package.manifest_path
                ));
            }
        }
    }
    errors
}

#[derive(Default)]
struct NativeImports {
    errors: Vec<&'static str>,
}

impl<'ast> Visit<'ast> for NativeImports {
    fn visit_item_extern_crate(&mut self, item: &'ast syn::ItemExternCrate) {
        let name = item.ident.to_string();
        if name == "libloading" {
            self.errors.push("runtime library loader");
        }
        if name.ends_with("_sys") || name.contains("_sys_") {
            self.errors.push("direct sys import");
        }
    }

    fn visit_item_foreign_mod(&mut self, _item: &'ast syn::ItemForeignMod) {
        self.errors.push("local FFI import (add a binding wrapper)");
    }

    fn visit_path(&mut self, path: &'ast syn::Path) {
        for segment in &path.segments {
            let name = segment.ident.to_string();
            if name == "libloading" {
                self.errors.push("runtime library loader");
            }
            if name.ends_with("_sys") || name.contains("_sys_") {
                self.errors.push("direct sys import");
            }
        }
        visit::visit_path(self, path);
    }

    fn visit_use_tree(&mut self, tree: &'ast syn::UseTree) {
        let name = match tree {
            syn::UseTree::Path(item) => Some(&item.ident),
            syn::UseTree::Name(item) => Some(&item.ident),
            syn::UseTree::Rename(item) => Some(&item.ident),
            _ => None,
        };
        if let Some(name) = name {
            let name = name.to_string();
            if name == "libloading" {
                self.errors.push("runtime library loader");
            }
            if name.ends_with("_sys") || name.contains("_sys_") {
                self.errors.push("direct sys import");
            }
        }
        visit::visit_use_tree(self, tree);
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
                    self.errors.push("runtime symbol probe");
                }
                if ["OH_", "OHOS_", "napi_"]
                    .iter()
                    .any(|prefix| name.starts_with(prefix))
                {
                    self.errors.push("raw native call (use a binding wrapper)");
                }
            }
        }
        visit::visit_expr_call(self, call);
    }
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
    let mut errors = dependency_errors(&metadata);
    for directory in ["crates", "rust_example", "xtask"] {
        for file in crate::rust_files(&root.join(directory))? {
            let source = file.strip_prefix(root)?.display().to_string();
            let syntax = syn::parse_file(&fs::read_to_string(&file)?)
                .map_err(|error| format!("{source}: {error}"))?;
            let mut visitor = NativeImports::default();
            visitor.visit_file(&syntax);
            visitor.errors.sort();
            visitor.errors.dedup();
            errors.extend(
                visitor
                    .errors
                    .into_iter()
                    .map(|error| format!("{source}: {error}")),
            );
        }
    }
    if !errors.is_empty() {
        return Err(errors.join("\n").into());
    }
    println!("Native boundary passed: {} workspace packages; no direct sys dependencies or runtime loaders.",
        metadata.packages.len());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checks_package_names_not_dependency_aliases_and_includes_target_dependencies() {
        let metadata = serde_json::from_str(r#"{"packages":[{
            "manifest_path":"Cargo.toml",
            "dependencies":[
                {"name":"native-sys","rename":"safe","target":"cfg(target_env = \"ohos\")","features":[]},
                {"name":"napi-ohos","features":["dyn-symbols"]}
            ],
            "features":{"dynamic":["napi-ohos?/dyn-symbols"]}
        }]}"#).unwrap();
        assert_eq!(dependency_errors(&metadata).len(), 3);
    }

    #[test]
    fn parses_imports_and_calls_without_matching_comments_or_string_contents() {
        let source = syn::parse_file(
            r#"
            // use libloading::Library;
            const MESSAGE: &str = "OH_RawCall(); dlopen(); extern C {}";
            fn safe() {}
        "#,
        )
        .unwrap();
        let mut visitor = NativeImports::default();
        visitor.visit_file(&source);
        assert!(visitor.errors.is_empty());
        for source in [
            "use native_sys as renamed;",
            "extern crate native_sys as renamed;",
            "use libloading::{Library};",
            "unsafe extern \"C\" { fn foreign(); }",
            "fn raw() { native::OH_RawCall(); }",
            "fn dynamic() { dlsym(); }",
        ] {
            let mut visitor = NativeImports::default();
            visitor.visit_file(&syn::parse_file(source).unwrap());
            assert!(!visitor.errors.is_empty(), "{source}");
        }
    }
}
