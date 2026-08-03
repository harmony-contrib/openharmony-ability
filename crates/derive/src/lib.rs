use proc_macro::TokenStream;

use syn::ItemFn;

/// Defines one native ability module.
///
/// The attribute no longer accepts `webview` or `protocol` arguments. WebView is an application
/// plugin with an explicit ArkTS host slot, rather than a framework-level render special case.
#[proc_macro_attribute]
pub fn ability(attr: TokenStream, item: TokenStream) -> TokenStream {
    if !attr.is_empty() {
        return syn::Error::new(
            proc_macro2::Span::call_site(),
            "#[ability] no longer accepts arguments; compose capability plugins in ArkTS instead",
        )
        .to_compile_error()
        .into();
    }

    let ast = syn::parse_macro_input!(item as ItemFn);
    let fn_name = &ast.sig.ident;
    let block = &ast.block;
    let arg = &ast.sig.inputs;

    let render = quote::quote! {
        #[napi_derive_ohos::napi]
        pub fn render<'a>(
            env: &'a napi_ohos::Env,
            bindings: napi_ohos::bindgen_prelude::ObjectRef,
            #[napi(ts_arg_type = "NodeContent")] slot: openharmony_ability::arkui::ArkUIHandle,
        ) -> napi_ohos::Result<()> {
            let root = openharmony_ability::render(env, bindings, slot, (*APP).clone())?;
            ROOT_NODE.replace(Some(root));
            Ok(())
        }
    };

    let expanded = quote::quote! {
        pub(crate) fn #fn_name(#arg) #block

        mod openharmony_ability_mod {
            use super::*;

            static APP: std::sync::LazyLock<openharmony_ability::OpenHarmonyApp> =
                std::sync::LazyLock::new(openharmony_ability::OpenHarmonyApp::new);

            thread_local! {
                pub static ROOT_NODE: std::cell::RefCell<Option<openharmony_ability::arkui::RootNode>> = std::cell::RefCell::new(None);
            }

            #[napi_derive_ohos::napi]
            pub fn on_back_press_intercept() -> bool {
                (*APP).get_back_press_interceptor()
            }

            #[napi_derive_ohos::napi]
            pub fn init<'a>(
                env: &'a napi_ohos::Env,
                #[napi(ts_arg_type = "AbilityInitContext")]
                context: Option<napi_ohos::bindgen_prelude::Object<'a>>,
            ) -> napi_ohos::Result<openharmony_ability::ApplicationLifecycle<'a>> {
                let init_context = openharmony_ability::AbilityInitContext::from_object(context.as_ref())?;
                let resource_manager = openharmony_ability::ResourceManager::from_init_context(*env, context.as_ref())?;

                // Initialize version information from ArkTS side
                openharmony_ability::version::init(
                    init_context.sdk_api_version.unwrap_or(0),
                    init_context.distribution_api_version.unwrap_or(0),
                );
                log::info!(
                    "OHOS version: sdk_api={}, distribution_api={}",
                    openharmony_ability::version::sdk_api_version(),
                    openharmony_ability::version::distribution_api_version(),
                );

                (*APP).set_init_context(init_context);
                (*APP).set_resource_manager(resource_manager);
                let lifecycle_handle = openharmony_ability::create_lifecycle_handle(env, (*APP).clone())?;
                #fn_name((*APP).clone());
                Ok(lifecycle_handle)
            }

            /// Synchronous ArkTS platform callback -> Rust plugin decision port.
            ///
            /// The N-API value is scoped to this call and the returned value must be produced
            /// before ArkTS resumes the originating platform callback. It is the dedicated
            /// typed inbound event port for ArkTS plugins.
            #[napi_derive_ohos::napi]
            pub fn on_bridge_sync_event<'a>(
                env: &'a napi_ohos::Env,
                plugin_id: String,
                event: String,
                request_type_name: String,
                response_type_name: String,
                value: napi_ohos::bindgen_prelude::Unknown<'a>,
            ) -> napi_ohos::Result<napi_ohos::bindgen_prelude::Unknown<'a>> {
                let event = openharmony_ability::BridgeMainThreadEvent::new(
                    env,
                    plugin_id,
                    event,
                    request_type_name,
                    response_type_name,
                    value,
                )?;
                (*APP).dispatch_bridge_main_thread_event(event)
            }

            /// ArkTS-only lifecycle transitions, currently UI-context readiness transitions.
            #[napi_derive_ohos::napi]
            pub fn on_bridge_lifecycle(kind: String) -> napi_ohos::Result<()> {
                let event = openharmony_ability::PluginLifecycleEvent::from_arkts(&kind)?;
                (*APP).dispatch_plugin_lifecycle(event)
            }

            #render
        }
    };

    expanded.into()
}
