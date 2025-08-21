use darling::FromMeta;
use proc_macro::TokenStream;
use syn::ItemFn;

#[derive(FromMeta, Default, Debug)]
struct AbilityArgs {
    #[darling(default)]
    webview: bool,
    #[darling(default)]
    protocol: Option<String>,
}

#[proc_macro_attribute]
pub fn ability(attr: TokenStream, item: TokenStream) -> TokenStream {
    let ast = syn::parse_macro_input!(item as ItemFn);
    let fn_name = &ast.sig.ident;
    let block = &ast.block;
    let arg = &ast.sig.inputs;

    let args = if attr.is_empty() {
        AbilityArgs::default()
    } else {
        match darling::ast::NestedMeta::parse_meta_list(proc_macro2::TokenStream::from(attr)) {
            Ok(list) => match AbilityArgs::from_list(&list) {
                Ok(args) => args,
                Err(e) => {
                    return TokenStream::from(e.write_errors());
                }
            },
            Err(e) => {
                return TokenStream::from(e.to_compile_error());
            }
        }
    };

    let protocol_registrations = args
        .protocol
        .as_ref()
        .map(|protocols| {
            protocols
                .split(",")
                .map(|protocol| {
                    let protocol_lit = syn::LitStr::new(protocol, proc_macro2::Span::call_site());
                    quote::quote! {
                        openharmony_ability::native_web::CustomProtocol::add_protocol_with_option(#protocol_lit, 
                            openharmony_ability::native_web::CustomProtocolOption::Standard | 
                            openharmony_ability::native_web::CustomProtocolOption::CorsEnabled | 
                            openharmony_ability::native_web::CustomProtocolOption::CspBypassing |
                            openharmony_ability::native_web::CustomProtocolOption::FetchEnabled |
                            openharmony_ability::native_web::CustomProtocolOption::CodeCacheEnabled
                        );
                    }
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let render = if args.webview {
        quote::quote! {
            #[openharmony_ability::napi_derive::napi]
            pub fn webview_render<'a>(
                env: &'a openharmony_ability::napi::Env,
                helper: openharmony_ability::napi::bindgen_prelude::ObjectRef,
            ) -> openharmony_ability::napi::Result<openharmony_ability::WebViewComponentEventCallback<'a>> {
                let callback = openharmony_ability::render(env, helper, (*APP).clone())?;
                Ok(callback)
            }
        }
    } else {
        quote::quote! {
            #[openharmony_ability::napi_derive::napi]
            pub fn render<'a>(
                env: &'a openharmony_ability::napi::Env,
                helper: openharmony_ability::napi::bindgen_prelude::ObjectRef,
                slot: openharmony_ability::arkui::ArkUIHandle,
            ) -> openharmony_ability::napi::Result<()> {
                let root = openharmony_ability::render(env, helper, slot, (*APP).clone())?;
                ROOT_NODE.replace(Some(root));
                Ok(())
            }
        }
    };

    // Register custom protocol if protocol is specified and webview is enabled
    let protocol_registrations_apply = if args.protocol.is_some() && args.webview {
        quote::quote! {
            #[openharmony_ability::napi_derive::napi]
            pub fn register_custom_protocol<'a>(
                env: &'a openharmony_ability::napi::Env,
            ) -> openharmony_ability::napi::Result<()> {
                #(#protocol_registrations)*

                openharmony_ability::native_web::CustomProtocol::register();

                Ok(())
            }
        }
    } else {
        quote::quote! {}
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

            #protocol_registrations_apply

            #[openharmony_ability::napi_derive::napi]
            pub fn init<'a>(
                env: &'a openharmony_ability::napi::Env,
            ) -> openharmony_ability::napi::Result<openharmony_ability::ApplicationLifecycle<'a>> {
                let lifecycle_handle = openharmony_ability::create_lifecycle_handle(env, (*APP).clone())?;
                #fn_name((*APP).clone());
                Ok(lifecycle_handle)
            }

            #render
        }
    };

    f.into()
}
