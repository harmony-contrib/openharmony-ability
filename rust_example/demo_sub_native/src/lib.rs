use std::sync::{LazyLock, RwLock};

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{AvoidAreaType, OpenHarmonyApp};
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_webview::{WebviewBridgePlugin, WebviewCreateRequest, WebviewExt};
use openharmony_ability_plugin_window::{WindowBridgePlugin, WindowExt};

static APP: LazyLock<RwLock<Option<OpenHarmonyApp>>> = LazyLock::new(|| RwLock::new(None));

fn current_app() -> Result<OpenHarmonyApp> {
    APP.read()
        .map_err(|_| Error::from_reason("Failed to read sub-window application state"))?
        .as_ref()
        .cloned()
        .ok_or_else(|| Error::from_reason("Sub-window native module is not initialized"))
}

#[napi]
pub async fn create_sub_window_webview() -> Result<()> {
    current_app()?
        .webview()?
        .create(
            WebviewCreateRequest::new("demo_sub_window_webview")
                .transparent(true)
                .url("https://example.com"),
        )
        .await?;
    Ok(())
}

/// Queries the window that owns this module's DefaultXComponent, not the Ability main window.
#[napi]
pub async fn sub_window_keyboard_inset() -> Result<i32> {
    Ok(current_app()?
        .window()?
        .query_avoid_area(AvoidAreaType::Keyboard)
        .await?
        .bottom_rect
        .height)
}

#[ability]
fn openharmony_app(app: OpenHarmonyApp) {
    APP.write().unwrap().replace(app.clone());
    app.register_plugin(WebviewBridgePlugin)
        .expect("sub-window WebView facade must be registered");
    app.register_plugin(WindowBridgePlugin)
        .expect("sub-window Window facade must be registered");
    app.run_loop(|_event| {});
}
