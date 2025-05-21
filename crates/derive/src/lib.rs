use proc_macro::TokenStream;
use syn::{parse::Parse, parse::ParseStream, parse_macro_input, ItemFn};

struct AbilityArgs {
    webview: bool,
}

impl Parse for AbilityArgs {
    fn parse(input: ParseStream) -> syn::Result<Self> {
        let mut webview = false;
        while !input.is_empty() {
            let ident: syn::Ident = input.parse()?;
            if ident == "webview" {
                webview = true;
            }
            if !input.is_empty() {
                input.parse::<syn::Token![,]>()?;
            }
        }
        Ok(AbilityArgs { webview })
    }
}

#[proc_macro_attribute]
pub fn ability(attr: TokenStream, item: TokenStream) -> TokenStream {
    let ast = syn::parse_macro_input!(item as ItemFn);
    let fn_name = &ast.sig.ident;
    let block = &ast.block;
    let arg = &ast.sig.inputs;

    // Parse attribute arguments
    let args = parse_macro_input!(attr as AbilityArgs);
    let has_webview = args.webview;

    let render = if has_webview {
        quote::quote! {
            #[openharmony_ability::napi_derive::napi]
            pub fn webview_render(
                env: &openharmony_ability::napi::Env,
            ) -> openharmony_ability::napi::Result<()> {
                Ok(())
            }
        }
    } else {
        quote::quote! {
            #[openharmony_ability::napi_derive::napi]
            pub fn render(
                env: &openharmony_ability::napi::Env,
                slot: openharmony_ability::arkui::ArkUIHandle,
            ) -> openharmony_ability::napi::Result<()> {
                let root = openharmony_ability::render(env, slot, (*APP).clone())?;
                ROOT_NODE.replace(Some(root));
                Ok(())
            }
        }
    };

    let f = quote::quote! {
        pub(crate) fn #fn_name(#arg) #block

        mod openharmony_ability_mod {
            use super::*;
            use openharmony_ability::napi as napi_ohos;

            static APP: std::sync::LazyLock<openharmony_ability::OpenHarmonyApp> =
                std::sync::LazyLock::new(|| openharmony_ability::OpenHarmonyApp::new());

            thread_local! {
                pub static ROOT_NODE: std::cell::RefCell<Option<openharmony_ability::arkui::RootNode>> = std::cell::RefCell::new(None);
            }

            #[openharmony_ability::napi_derive::napi]
            pub fn init<'a>(
                env: &'a openharmony_ability::napi::Env,
                helper: openharmony_ability::ArkTSHelper,
            ) -> openharmony_ability::napi::Result<openharmony_ability::ApplicationLifecycle<'a>> {
                let lifecycle_handle =
                    openharmony_ability::create_lifecycle_handle(env, helper, (*APP).clone())?;
                #fn_name((*APP).clone());
                Ok(lifecycle_handle)
            }

            #render
        }
    };

    f.into()
}
