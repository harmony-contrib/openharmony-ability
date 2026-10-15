use proc_macro::TokenStream;

use syn::ItemFn;

/// Defines one native ability module.
///
/// The attribute no longer accepts `webview` or `protocol` arguments. WebView is an application
/// plugin that mounts into this module's component root, rather than a framework-level render
/// special case.
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
            #[napi(ts_arg_type = "NodeContent")] slot: ::openharmony_ability::arkui::ArkUIHandle,
            render_owner: String,
            // Option<i64>: an outdated HAR calling the pre-window_id signature
            // degrades to the primary instance (id 0) instead of failing NAPI
            // arg marshalling (mirrors lifecycle.rs's window_id_arg pattern).
            window_id: Option<i64>,
        ) -> napi_ohos::Result<()> {
            let window_id = window_id.unwrap_or(0);
            if render_owner.is_empty() {
                return Err(napi_ohos::Error::from_reason("renderOwner must not be empty"));
            }
            if ROOT_NODE.with(|node| node.borrow().is_some()) {
                return Err(napi_ohos::Error::from_reason(
                    "This native module is already rendered by another DefaultXComponent; use a distinct native module for every active component",
                ));
            }
            let root = ::openharmony_ability::render(
                env,
                slot,
                render_owner.clone(),
                window_id,
                (*APP).clone(),
            )?;
            ROOT_NODE.with(|node| *node.borrow_mut() = Some((render_owner, root)));
            Ok(())
        }

        #[napi_derive_ohos::napi]
        pub fn dispose_render(render_owner: String) {
            ROOT_NODE.with(|node| {
                let owns_render = node
                    .borrow()
                    .as_ref()
                    .map(|(owner, _)| owner == &render_owner)
                    .unwrap_or(false);
                if owns_render {
                    let root = node.borrow_mut().take();
                    drop(root);
                    (*APP).release_render(&render_owner);
                }
            });
        }

        #[napi_derive_ohos::napi]
        pub fn dispose_all_renders() {
            ROOT_NODE.with(|node| {
                let root = node.borrow_mut().take();
                if let Some((owner, root)) = root {
                    drop(root);
                    (*APP).release_render(&owner);
                }
            });
        }
    };

    let expanded = quote::quote! {
        pub(crate) fn #fn_name(#arg) #block

        mod openharmony_ability_mod {
            use super::*;

            static APP: std::sync::LazyLock<::openharmony_ability::OpenHarmonyApp> =
                std::sync::LazyLock::new(::openharmony_ability::OpenHarmonyApp::new);
            static APP_CONFIGURED: std::sync::OnceLock<()> = std::sync::OnceLock::new();

            struct BridgeSessionInitGuard {
                owner: Option<String>,
            }

            impl BridgeSessionInitGuard {
                fn new(owner: String) -> Self {
                    Self { owner: Some(owner) }
                }

                fn disarm(&mut self) {
                    self.owner = None;
                }
            }

            impl Drop for BridgeSessionInitGuard {
                fn drop(&mut self) {
                    if let Some(owner) = self.owner.take() {
                        (*APP).release_bridge_session(&owner);
                    }
                }
            }

            thread_local! {
                pub static ROOT_NODE: std::cell::RefCell<Option<(String, ::openharmony_ability::arkui::RootNode)>> = std::cell::RefCell::new(None);
            }

            #[napi_derive_ohos::napi]
            pub fn on_back_press_intercept() -> bool {
                (*APP).get_back_press_interceptor()
            }

            /// ArkTS pre-IME key forward (issue Eulogizethesun/tauri#109):
            /// MainPage.onKeyPreIme feeds every key the web sees into the
            /// tao event loop through the same `Event::Input` dispatch the
            /// (structurally unreachable, see `dispatch_key_event`'s doc)
            /// NDK XComponent path would have used. `action`: 0 = Down,
            /// 1 = Up (KeyType only has Down/Up).
            #[napi_derive_ohos::napi]
            pub fn notify_key_event(key_code: i32, action: i32, device_id: i64) {
                use ::openharmony_ability::xcomponent::{Action, EventSource, KeyCode, KeyEventData};
                // try_from_raw, NOT From: EnumFrom's generated From hits
                // unreachable!() on key codes absent from the binding's enum,
                // and the ArkTS InputKit keycode table may be newer — a panic
                // here would cross the NAPI boundary. The raw type is i32
                // (OH_NativeXComponent_KeyCode; KEY_UNKNOWN = -1).
                let code = KeyCode::try_from_raw(key_code).unwrap_or(KeyCode::Unknown);
                let action = match action {
                    0 => Action::Down,
                    1 => Action::Up,
                    _ => Action::Unknown,
                };
                (*APP).dispatch_key_event(KeyEventData {
                    code,
                    action,
                    device_id,
                    source: EventSource::Keyboard,
                    // `timestamp: 0` is a placeholder, harmless today: tao's
                    // OHOS backend never reads this field — repeat detection
                    // is keycode-based (pressed-keys set), and the winit-level
                    // KeyEvent it dispatches carries no time. (The ArkTS
                    // KeyEvent does expose `timestamp` — ns since boot, same
                    // unit as the NDK field — so forward it here if a
                    // consumer ever appears.)
                    timestamp: 0,
                });
            }

            #[napi_derive_ohos::napi]
            pub fn init<'a>(
                env: &'a napi_ohos::Env,
                bindings: napi_ohos::bindgen_prelude::ObjectRef,
                bridge_owner: String,
                #[napi(ts_arg_type = "AbilityInitContext")]
                context: Option<napi_ohos::bindgen_prelude::Object<'a>>,
            ) -> napi_ohos::Result<::openharmony_ability::ApplicationLifecycle<'a>> {
                let init_context = ::openharmony_ability::AbilityInitContext::from_object(context.as_ref())?;
                // Initialize version info from ArkTS side (restored from upstream baseline;
                // dropped during the BridgeSessionInitGuard refactor — without this, every
                // version gate reads 0 and short-circuits: global-shortcut/autostart).
                ::openharmony_ability::version::init(
                    init_context.sdk_api_version.unwrap_or(0),
                    init_context.distribution_api_version.unwrap_or(0),
                );
                ::log::info!(
                    "OHOS version: sdk_api={}, distribution_api={}",
                    ::openharmony_ability::version::sdk_api_version(),
                    ::openharmony_ability::version::distribution_api_version(),
                );
                ::openharmony_ability::attach_bridge_session(env, bindings, &bridge_owner, &APP)?;
                let mut bridge_guard = BridgeSessionInitGuard::new(bridge_owner);
                (*APP).set_init_context(init_context);
                // A native module can outlive one UIAbility instance. Configure its process-wide
                // Rust plugin registry exactly once, while still refreshing the per-session init
                // context and lifecycle handle on every Ability recreation.
                APP_CONFIGURED.get_or_init(|| #fn_name((*APP).clone()));
                let lifecycle_handle = ::openharmony_ability::create_lifecycle_handle(env, (*APP).clone())?;
                bridge_guard.disarm();
                Ok(lifecycle_handle)
            }

            /// Releases the Ability-session transport without touching this module's independent
            /// DefaultXComponent render owner. Stale owners are ignored.
            #[napi_derive_ohos::napi]
            pub fn dispose_bridge(bridge_owner: String) {
                (*APP).release_bridge_session(&bridge_owner);
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
                let event = ::openharmony_ability::BridgeMainThreadEvent::new(
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
            /// `window_id` names the originating UIAbility instance (design.md D8,
            /// openspec multi-uiability-windows): 0 = primary, or a spawned
            /// instance's tauri window id.
            #[napi_derive_ohos::napi]
            pub fn on_bridge_lifecycle(kind: String, window_id: Option<i64>) -> napi_ohos::Result<()> {
                // Option<i64>: an outdated HAR calling the pre-window_id
                // signature degrades to the primary instance (id 0) instead of
                // failing NAPI arg marshalling (mirrors lifecycle.rs's
                // window_id_arg pattern).
                let window_id = window_id.unwrap_or(0);
                let event = ::openharmony_ability::PluginLifecycleEvent::from_arkts(&kind, window_id)?;
                (*APP).dispatch_plugin_lifecycle(event)
            }

            #render
        }
    };

    expanded.into()
}
