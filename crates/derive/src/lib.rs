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
            render_owner: String,
        ) -> napi_ohos::Result<()> {
            if render_owner.is_empty() {
                return Err(napi_ohos::Error::from_reason("renderOwner must not be empty"));
            }
            let root = openharmony_ability::render(env, bindings, slot, (*APP).clone())?;
            ROOT_NODES.with(|nodes| {
                let mut nodes = nodes.borrow_mut();
                if let Some(index) = nodes.iter().position(|(owner, _)| owner == &render_owner) {
                    nodes.remove(index);
                }
                nodes.push((render_owner, root));
            });
            Ok(())
        }

        #[napi_derive_ohos::napi]
        pub fn dispose_render(render_owner: String) {
            ROOT_NODES.with(|nodes| {
                let mut nodes = nodes.borrow_mut();
                if let Some(index) = nodes.iter().position(|(owner, _)| owner == &render_owner) {
                    nodes.remove(index);
                }
            });
        }

        #[napi_derive_ohos::napi]
        pub fn dispose_all_renders() {
            ROOT_NODES.with(|nodes| nodes.borrow_mut().clear());
        }
    };

    let expanded = quote::quote! {
        pub(crate) fn #fn_name(#arg) #block

        mod openharmony_ability_mod {
            use super::*;

            static APP: std::sync::LazyLock<openharmony_ability::OpenHarmonyApp> =
                std::sync::LazyLock::new(openharmony_ability::OpenHarmonyApp::new);
            static APP_CONFIGURED: std::sync::OnceLock<()> = std::sync::OnceLock::new();

            thread_local! {
                pub static ROOT_NODES: std::cell::RefCell<Vec<(String, openharmony_ability::arkui::RootNode)>> = std::cell::RefCell::new(Vec::new());
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
                (*APP).set_init_context(init_context);
                // A native module can outlive one UIAbility instance. Configure its process-wide
                // Rust plugin registry exactly once, while still refreshing the per-session init
                // context and lifecycle handle on every Ability recreation.
                APP_CONFIGURED.get_or_init(|| #fn_name((*APP).clone()));
                let lifecycle_handle = openharmony_ability::create_lifecycle_handle(env, (*APP).clone())?;
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
