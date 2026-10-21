use crate::Result;
use quote::ToTokens;
use std::{collections::BTreeSet, fmt::Write, fs, path::Path};
use syn::{
    parse::{Parse, ParseStream},
    Expr, ImplItem, Item, Lit, LitStr, Token, Type,
};

const TABLE: &str = "docs/napi-contracts.md";

struct NamedType {
    name: String,
    rust_type: String,
    source: String,
}

#[derive(Default)]
struct Inventory {
    named: Vec<NamedType>,
    objects: Vec<(String, String, String)>,
    plugins: Vec<(String, String, String, String)>,
}

struct TypeDeclaration(Type, LitStr);

impl Parse for TypeDeclaration {
    fn parse(input: ParseStream<'_>) -> syn::Result<Self> {
        let rust_type = input.parse()?;
        input.parse::<Token![,]>()?;
        let name = input.parse()?;
        if input.peek(Token![,]) {
            input.parse::<Token![,]>()?;
        }
        Ok(Self(rust_type, name))
    }
}

fn tokens(value: &impl ToTokens) -> String {
    value
        .to_token_stream()
        .to_string()
        .replace(" :: ", "::")
        .replace(" < ", "<")
        .replace(" >", ">")
}

fn string_literal(
    expr: &Expr,
    declarations: &[Item],
    visiting: &mut BTreeSet<String>,
) -> Result<String> {
    match expr {
        Expr::Lit(literal) => match &literal.lit {
            Lit::Str(value) => Ok(value.value()),
            _ => Err("Contract names must be string literals".into()),
        },
        Expr::Path(path) if path.path.get_ident().is_some() => {
            let name = path.path.get_ident().unwrap().to_string();
            if !visiting.insert(name.clone()) {
                return Err(format!("Cyclic contract name constant: {name}").into());
            }
            let value = declarations
                .iter()
                .find_map(|item| match item {
                    Item::Const(item) if item.ident == name => Some(&item.expr),
                    _ => None,
                })
                .ok_or_else(|| format!("Cannot resolve contract name constant: {name}"))?;
            string_literal(value, declarations, visiting)
        }
        _ => Err("Contract names must be string literals or local string constants".into()),
    }
}

fn named_const(items: &[ImplItem], name: &str, declarations: &[Item]) -> Result<String> {
    items
        .iter()
        .find_map(|item| match item {
            ImplItem::Const(item) if item.ident == name => Some(string_literal(
                &item.expr,
                declarations,
                &mut BTreeSet::new(),
            )),
            _ => None,
        })
        .ok_or_else(|| format!("Missing {name} in contract implementation"))?
}

impl Inventory {
    fn collect(&mut self, items: &[Item], source: &str, scope: &str) -> Result<()> {
        for item in items {
            match item {
                Item::Mod(module) => {
                    let test_only = module.attrs.iter().any(|attr| {
                        attr.path().is_ident("cfg")
                            && attr
                                .parse_args::<syn::Path>()
                                .is_ok_and(|path| path.is_ident("test"))
                    });
                    if !test_only {
                        if let Some((_, items)) = &module.content {
                            self.collect(items, source, &format!("{scope}{}::", module.ident))?;
                        }
                    }
                }
                Item::Macro(item)
                    if item.mac.path.segments.last().is_some_and(|segment| {
                        segment.ident == "impl_bridge_napi_type"
                            || segment.ident == "impl_builtin_napi_type"
                    }) =>
                {
                    let TypeDeclaration(rust_type, name) = syn::parse2(item.mac.tokens.clone())?;
                    self.named.push(NamedType {
                        name: name.value(),
                        rust_type: tokens(&rust_type),
                        source: source.into(),
                    });
                }
                Item::Impl(item) => {
                    let Some((_, path, _)) = &item.trait_ else {
                        continue;
                    };
                    match path
                        .segments
                        .last()
                        .map(|segment| segment.ident.to_string())
                        .as_deref()
                    {
                        Some("BridgeNapiType") => self.named.push(NamedType {
                            name: named_const(&item.items, "TYPE_NAME", items)?,
                            rust_type: tokens(&item.self_ty),
                            source: source.into(),
                        }),
                        Some("BridgePlugin") => {
                            let mode = item
                                .items
                                .iter()
                                .find_map(|item| match item {
                                    ImplItem::Type(item) if item.ident == "Mode" => {
                                        Some(tokens(&item.ty))
                                    }
                                    _ => None,
                                })
                                .ok_or("BridgePlugin is missing Mode")?;
                            let contexts = item
                                .items
                                .iter()
                                .find_map(|item| match item {
                                    ImplItem::Const(item) if item.ident == "REQUIRED_CONTEXTS" => {
                                        Some(tokens(&item.expr))
                                    }
                                    _ => None,
                                })
                                .unwrap_or_else(|| "&[] (trait default)".into());
                            self.plugins.push((
                                named_const(&item.items, "ID", items)?,
                                mode,
                                contexts,
                                source.into(),
                            ));
                        }
                        _ => {}
                    }
                }
                Item::Struct(item) => {
                    let mut object = false;
                    for attr in &item.attrs {
                        if attr
                            .path()
                            .segments
                            .last()
                            .is_some_and(|segment| segment.ident == "napi")
                        {
                            attr.parse_nested_meta(|meta| {
                                if meta.path.is_ident("object") {
                                    object = true;
                                }
                                Ok(())
                            })?;
                        }
                    }
                    if object {
                        let fields = item
                            .fields
                            .iter()
                            .map(|field| {
                                let name = field
                                    .ident
                                    .as_ref()
                                    .map(ToString::to_string)
                                    .ok_or("N-API object fields must be named")?;
                                let mut field_name = name;
                                for attr in &field.attrs {
                                    if attr.path().is_ident("napi") {
                                        attr.parse_nested_meta(|meta| {
                                            if meta.path.is_ident("js_name") {
                                                let value: LitStr = meta.value()?.parse()?;
                                                write!(field_name, " (JS: {})", value.value())
                                                    .unwrap();
                                            }
                                            Ok(())
                                        })?;
                                    }
                                }
                                Ok(format!("{field_name}: {}", tokens(&field.ty)))
                            })
                            .collect::<Result<Vec<_>>>()?;
                        self.objects.push((
                            format!("{scope}{}", item.ident),
                            format!("{{ {} }}", fields.join(", ")),
                            source.into(),
                        ));
                    }
                }
                _ => {}
            }
        }
        Ok(())
    }

    fn render(mut self) -> Result<String> {
        self.named.sort_by(|left, right| left.name.cmp(&right.name));
        self.objects.sort();
        self.plugins.sort();
        let mut names = BTreeSet::new();
        for contract in &self.named {
            if !names.insert(&contract.name) {
                return Err(format!("Duplicate bridge type name: {}", contract.name).into());
            }
            if contract.name.is_empty()
                || !contract
                    .name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
            {
                return Err(format!("Invalid bridge type name: {}", contract.name).into());
            }
        }
        let mut output = String::from(
            "# Named N-API contracts\n\n\
             <!-- Generated by cargo run -p xtask -- contracts. Do not edit. -->\n\n\
             This is the canonical inventory of Rust bridge declarations in `crates/ability` and\n\
             `crates/plugin-*`, across all feature configurations (excluding test-only modules).\n\
             Both macro declarations and handwritten `BridgeNapiType` implementations are included.\n\
             This is not a JSON protocol. ArkTS must use these exact ABI names.\n\n\
             Regenerate with `cargo run -p xtask -- contracts`; CI checks with\n\
             `cargo run -p xtask -- contracts --check`. Action routing, lifecycle rules and\n\
             platform failure policies remain in the [plugin standard](plugin-development-standard.md).\n\n\
             ## Plugin declarations\n\n\
             | Plugin ID | Rust mode | Required contexts | Source |\n\
             | --- | --- | --- | --- |\n",
        );
        for (id, mode, contexts, source) in self.plugins {
            writeln!(
                output,
                "| `{id}` | `{mode}` | `{contexts}` | [source](../{source}) |"
            )?;
        }
        output.push_str(
            "\n## Bridge type names\n\n\
             | ABI type name | Rust type | Source |\n\
             | --- | --- | --- |\n",
        );
        for contract in self.named {
            writeln!(
                output,
                "| `{}` | `{}` | [source](../{}) |",
                contract.name, contract.rust_type, contract.source
            )?;
        }
        output.push_str(
            "\n## N-API object layouts\n\n\
             Includes nested objects without an independent bridge name. Fields and types are\n\
             Rust declarations; N-API maps snake_case to camelCase unless an explicit JS name is\n\
             shown. Handwritten native-object conversions (for example `ResourceManagerRef`)\n\
             are defined by their linked source, not by an invented object layout.\n\n\
             | Rust object | Fields | Source |\n\
             | --- | --- | --- |\n",
        );
        for (rust_type, fields, source) in self.objects {
            writeln!(
                output,
                "| `{rust_type}` | `{fields}` | [source](../{source}) |"
            )?;
        }
        Ok(output)
    }
}

pub fn run(root: &Path, check: bool) -> Result<()> {
    let mut inventory = Inventory::default();
    let mut crates = fs::read_dir(root.join("crates"))?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<std::io::Result<Vec<_>>>()?;
    crates.sort();
    for directory in crates {
        let name = directory
            .file_name()
            .unwrap()
            .to_str()
            .ok_or("Non-UTF-8 crate name")?;
        if name != "ability" && !name.starts_with("plugin-") {
            continue;
        }
        for file in crate::rust_files(&directory.join("src"))? {
            let source = file
                .strip_prefix(root)?
                .to_str()
                .ok_or("Non-UTF-8 source path")?;
            let syntax = syn::parse_file(&fs::read_to_string(&file)?)
                .map_err(|error| format!("{source}: {error}"))?;
            let module = file.strip_prefix(directory.join("src"))?.with_extension("");
            let mut components = module
                .iter()
                .map(|part| part.to_string_lossy().into_owned())
                .collect::<Vec<_>>();
            if components
                .last()
                .is_some_and(|part| part == "lib" || part == "mod")
            {
                components.pop();
            }
            let crate_name = if name == "ability" {
                "openharmony_ability".into()
            } else {
                format!("openharmony_ability_{}", name.replace('-', "_"))
            };
            let mut scope = format!("{crate_name}::");
            for component in components {
                write!(scope, "{component}::")?;
            }
            inventory
                .collect(&syntax.items, source, &scope)
                .map_err(|error| format!("{source}: {error}"))?;
        }
    }
    let generated = inventory.render()?;
    let path = root.join(TABLE);
    if check {
        if fs::read_to_string(&path)? != generated {
            return Err(format!("{TABLE} is stale; run `cargo run -p xtask -- contracts`").into());
        }
        println!("{TABLE} matches Rust declarations.");
    } else {
        fs::write(path, generated)?;
        println!("Generated {TABLE}.");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(source: &str) -> Result<String> {
        let mut inventory = Inventory::default();
        inventory.collect(&syn::parse_file(source)?.items, "fixture.rs", "fixture::")?;
        inventory.render()
    }

    #[test]
    fn parses_multiline_qualified_macros_manual_impls_and_nested_objects() {
        let table = render(
            r#"
            // impl_bridge_napi_type!(NotReal, "comment.Fake");
            const DOCUMENTATION: &str = "impl_bridge_napi_type!(NotReal, \"string.Fake\")";
            #[napi(object)]
            struct Request { #[napi(js_name = "type")] item_type: String, child: Option<Child> }
            #[napi(object)] struct Child { enabled: bool }
            bridge::impl_bridge_napi_type!(
                Request,
                "test.Request",
            );
            impl<T> BridgeNapiType for Native<T> {
                const TYPE_NAME: &'static str = "test.Native";
            }
            #[cfg(test)] mod tests {
                impl_bridge_napi_type!(NotReal, "test.Fake");
            }
        "#,
        )
        .unwrap();
        assert!(table.contains("`test.Request`"));
        assert!(table.contains("`Native<T>`"));
        assert!(table.contains("item_type (JS: type): String"));
        assert!(table.contains("`fixture::Child`"));
        assert!(!table.contains("Fake"));
    }

    #[test]
    fn tracks_fields_names_and_plugin_requirements_without_action_inference() {
        let source = r#"
            #[napi(object)] struct Request { value: String }
            impl_bridge_napi_type!(Request, "test.Request");
            impl BridgePlugin for Plugin {
                type Mode = MainThreadSyncBridge;
                const ID: &'static str = "test.plugin";
                const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
                    &[BridgeContextRequirement::Ability];
            }
        "#;
        let before = render(source).unwrap();
        assert!(before.contains("MainThreadSyncBridge"));
        assert!(before.contains("BridgeContextRequirement::Ability"));
        for changed in [
            source.replace("value: String", "value: bool"),
            source.replace("test.Request", "test.NewRequest"),
            source.replace("::Ability", "::UiContext"),
        ] {
            assert_ne!(before, render(&changed).unwrap());
        }
    }

    #[test]
    fn fails_on_duplicates_invalid_names_and_unsupported_declarations() {
        assert!(render(
            r#"
            impl_bridge_napi_type!(First, "test.Type");
            impl_bridge_napi_type!(Second, "test.Type");
        "#
        )
        .is_err());
        assert!(render(r#"impl_bridge_napi_type!(Type, "invalid name");"#).is_err());
        assert!(render("impl_bridge_napi_type!(Type, NAME);").is_err());
        assert!(render("impl BridgeNapiType for Type {}").is_err());
    }

    #[test]
    fn orders_inventory_independently_of_source_order() {
        let first = r#"impl_bridge_napi_type!(A, "test.A");"#;
        let second = r#"impl_bridge_napi_type!(B, "test.B");"#;
        assert_eq!(
            render(&format!("{first}{second}")).unwrap(),
            render(&format!("{second}{first}")).unwrap()
        );
    }

    #[test]
    fn resolves_real_local_string_constants_and_rejects_cycles() {
        let source = r#"
            const PLUGIN_ID: &str = "test.plugin";
            impl BridgePlugin for Plugin {
                type Mode = AsyncBridge;
                const ID: &'static str = PLUGIN_ID;
            }
        "#;
        assert!(render(source).unwrap().contains("`test.plugin`"));
        assert!(render(&source.replace("\"test.plugin\"", "PLUGIN_ID")).is_err());
    }
}
