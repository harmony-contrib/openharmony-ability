use proc_macro::TokenStream;
use syn::parse::Parse;
use syn::punctuated::Punctuated;
use syn::Token;
use syn::{ItemFn, Meta, MetaNameValue};

#[derive(Default, Debug)]
struct AbilityArgs {
    webview: bool,
    protocol: Option<String>,
}

struct MetaList {
    metas: Punctuated<Meta, Token![,]>,
}

impl Parse for MetaList {
    fn parse(input: syn::parse::ParseStream) -> syn::Result<Self> {
        Ok(MetaList {
            metas: input.parse_terminated(Meta::parse, Token![,])?,
        })
    }
}

fn parse_ability_args(attr: TokenStream) -> syn::Result<AbilityArgs> {
    let mut args = AbilityArgs::default();

    if attr.is_empty() {
        return Ok(args);
    }

    // Parse attribute arguments as a list of Meta items
    // Convert proc_macro::TokenStream to proc_macro2::TokenStream for parsing
    let attr_stream = proc_macro2::TokenStream::from(attr);
    let meta_list = syn::parse2::<MetaList>(attr_stream)?;

    // Iterate over the meta items
    for meta in meta_list.metas {
        match meta {
            Meta::Path(path) => {
                // Handle named flags like `webview`
                if path.is_ident("webview") {
                    args.webview = true;
                }
            }
            Meta::NameValue(MetaNameValue { path, value, .. }) => {
                // Handle key-value pairs like `protocol = "value"`
                if path.is_ident("protocol") {
                    // Parse the value as an expression and extract string literal
                    if let syn::Expr::Lit(syn::ExprLit {
                        lit: syn::Lit::Str(lit_str),
                        ..
                    }) = value
                    {
                        args.protocol = Some(lit_str.value());
                    } else {
                        return Err(syn::Error::new_spanned(
                            value,
                            "protocol must be a string literal",
                        ));
                    }
                }
            }
            Meta::List(_) => {
                // Handle nested list-style attributes if needed
                // For now, we'll skip them
            }
        }
    }

    Ok(args)
}

#[proc_macro_attribute]
pub fn ability(attr: TokenStream, item: TokenStream) -> TokenStream {
    let ast = syn::parse_macro_input!(item as ItemFn);
    let fn_name = &ast.sig.ident;
    let block = &ast.block;
    let arg = &ast.sig.inputs;

    let args = match parse_ability_args(attr) {
        Ok(args) => args,
        Err(e) => {
            return TokenStream::from(e.to_compile_error());
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

    let render = quote::quote! {
        #[napi_derive_ohos::napi]
        pub fn render<'a>(
            env: &'a napi_ohos::Env,
            helper: napi_ohos::bindgen_prelude::ObjectRef,
            #[napi(ts_arg_type = "NodeContent")] slot: openharmony_ability::arkui::ArkUIHandle,
        ) -> napi_ohos::Result<()> {
            let root = openharmony_ability::render(env, helper, slot, (*APP).clone())?;
            ROOT_NODE.replace(Some(root));
            Ok(())
        }
    };

    // Register custom protocol if protocol is specified and webview is enabled
    let protocol_registrations_apply = if args.protocol.is_some() && args.webview {
        quote::quote! {
            #[napi_derive_ohos::napi]
            pub fn register_custom_protocol<'a>(
                env: &'a napi_ohos::Env,
            ) -> napi_ohos::Result<()> {
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

            static APP: std::sync::LazyLock<openharmony_ability::OpenHarmonyApp> =
                std::sync::LazyLock::new(|| openharmony_ability::OpenHarmonyApp::new());

            thread_local! {
                pub static ROOT_NODE: std::cell::RefCell<Option<openharmony_ability::arkui::RootNode>> = std::cell::RefCell::new(None);
            }

            #protocol_registrations_apply

            #[napi_derive_ohos::napi]
            pub fn init<'a>(
                env: &'a napi_ohos::Env,
            ) -> napi_ohos::Result<openharmony_ability::ApplicationLifecycle<'a>> {
                let lifecycle_handle = openharmony_ability::create_lifecycle_handle(env, (*APP).clone())?;
                #fn_name((*APP).clone());
                Ok(lifecycle_handle)
            }

            #render
        }
    };

    f.into()
}
