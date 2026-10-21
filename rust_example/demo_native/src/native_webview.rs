//! Native WebView assembled under a Rust-owned NodeContent parent.
use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Object, Env, Error, Result};
use openharmony_ability::arkui::component::{
    attribute::ArkUICommonAttribute, built_in_component::Column, content_root::ContentRoot,
};
use openharmony_ability::NativeAttachment;
use openharmony_ability_plugin_webview::{
    NativeWebviewEvents, NativeWebviewSettings, WebviewCreateRequest, WebviewExt,
    WebviewInitializationScript,
};
use std::{cell::RefCell, rc::Rc};
const ID: &str = "demo.native-webview";
struct DemoWebview {
    _events: NativeWebviewEvents,
    _attachment: NativeAttachment,
    content: ContentRoot,
}
thread_local! {static WEBVIEW:RefCell<Option<DemoWebview>>=RefCell::default();}
fn platform_error(error: impl std::fmt::Display) -> Error {
    Error::from_reason(error.to_string())
}
/// Creates the Rust parent and asynchronously attaches a first-navigation configured WebView.
#[napi]
pub fn demo_native_webview(env: &Env) -> Result<Object<'_>> {
    if WEBVIEW.with(|value| value.borrow().is_some()) {
        return Err(Error::from_reason(
            "Remove and release the previous native WebView first",
        ));
    }
    let app = super::current_app()?;
    let parent = Column::new().map_err(platform_error)?;
    parent.width(320.).map_err(platform_error)?;
    parent.height(180.).map_err(platform_error)?;
    let parent = parent.into_node();
    let attachment = NativeAttachment::new(&parent)?;
    let target = attachment.id();
    let events = NativeWebviewEvents::new(&app, ID.into(), target, |event| {
        log::info!(
            "native WebView {} target={} url={}",
            event.phase,
            event.target_id,
            event.url
        )
    })?;
    let mut content = ContentRoot::new(Env::from_raw(env.raw()))?;
    content.mount(Rc::clone(&parent)).map_err(platform_error)?;
    WEBVIEW.with(|value| {
        *value.borrow_mut() = Some(DemoWebview {
            _events: events,
            _attachment: attachment,
            content,
        })
    });
    let client = app.webview()?;
    std::thread::spawn(move || {
        let mut request=WebviewCreateRequest::new(ID).html("<h3 id='state'>Native WebView</h3><script>document.getElementById('state').textContent=window.initialNativeText</script>");
        request.javascript_enabled = Some(true);
        request.user_agent = Some("AbilityNativeWebviewDemo".into());
        request.initialization_scripts = Some(vec![WebviewInitializationScript {
            script: "window.initialNativeText='Configured before first navigation'".into(),
            script_rules: vec!["*".into()],
        }]);
        if let Err(error) = futures_executor::block_on(client.create_native(
            target,
            request,
            NativeWebviewSettings {
                id: ID.into(),
                scroll_enabled: true,
                injected_javascript: None,
                html_base_url: Some("https://example.invalid/".into()),
            },
        )) {
            log::error!("native WebView creation failed: {error}");
        }
    });
    WEBVIEW.with(|value| {
        value
            .borrow()
            .as_ref()
            .expect("stored WebView")
            .content
            .object(env)
    })
}
/// Waits for ArkTS native-edge retirement and script cleanup before the parent is released.
#[napi]
pub async fn demo_remove_native_webview() -> Result<()> {
    super::current_app()?.webview()?.handle(ID).remove().await
}
/// Releases the Rust parent on the UI thread after demoRemoveNativeWebview resolves.
#[napi]
pub fn demo_release_native_webview() {
    WEBVIEW.with(|value| {
        value.borrow_mut().take();
    });
}
