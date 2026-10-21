//! Native-tree presentation and callback snapshots, with no ArkTS references.
use super::{WebviewAcknowledgement, WebviewHandle};
use crate::{
    native_routes::{NativeEvents, Registration},
    WebviewBridgePlugin,
};
use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{impl_bridge_napi_type, OpenHarmonyApp};
use std::sync::Arc;
/// Configuration of a WebView embedded in a native attachment target.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct NativeWebviewSettings {
    /// Module-local controller ID.
    pub id: String,
    /// Whether the page can scroll.
    pub scroll_enabled: bool,
    /// Script evaluated at the end of each page load.
    pub injected_javascript: Option<String>,
    /// Base URL used for relative resources in inline HTML.
    pub html_base_url: Option<String>,
}
impl_bridge_napi_type!(NativeWebviewSettings, "ohos.webview.NativeSettings");

/// Native-embedding WebView state captured synchronously by ArkTS.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct NativeWebviewEvent {
    /// Module-local controller ID.
    pub id: String,
    /// Native attachment target paired with this controller.
    pub target_id: u32,
    /// start, finish, title, error, focus or blur.
    pub phase: String,
    /// Current document URL.
    pub url: String,
    /// Current document title.
    pub title: String,
    /// Whether navigation is in progress.
    pub loading: bool,
    /// Whether history has a previous entry.
    pub can_go_back: bool,
    /// Whether history has a following entry.
    pub can_go_forward: bool,
    /// Platform error description.
    pub message: Option<String>,
    /// Platform error code.
    pub code: Option<i32>,
}
impl_bridge_napi_type!(NativeWebviewEvent, "ohos.webview.NativeEvent");

/// Owns a callback declaration for one native attachment target.
/// A new declaration replaces the previous one; an old guard cannot remove it.
pub struct NativeWebviewEvents {
    target_id: u32,
    routes: Arc<NativeEvents<NativeWebviewEvent>>,
    registration: Arc<Registration<NativeWebviewEvent>>,
}
impl NativeWebviewEvents {
    /// Registers before creating the matching native controller.
    pub fn new(
        app: &OpenHarmonyApp,
        id: String,
        target_id: u32,
        callback: impl Fn(NativeWebviewEvent) + Send + Sync + 'static,
    ) -> Result<Self> {
        if id.trim().is_empty() || target_id == 0 {
            return Err(Error::from_reason(
                "native WebView events require an ID and attachment target",
            ));
        }
        let plugin = app
            .registered_plugin::<WebviewBridgePlugin>()?
            .ok_or_else(|| Error::from_reason("WebView plugin is not registered"))?;
        let routes = plugin.native_events.clone();
        let registration = routes.register(target_id, callback);
        Ok(Self {
            target_id,
            routes,
            registration,
        })
    }
}
impl Drop for NativeWebviewEvents {
    fn drop(&mut self) {
        self.routes.remove(self.target_id, &self.registration);
    }
}
impl WebviewHandle {
    /// Updates native-embedding preferences for subsequent documents.
    pub async fn configure_native(&self, settings: NativeWebviewSettings) -> Result<()> {
        if settings.id != self.id {
            return Err(Error::from_reason("native settings controller ID mismatch"));
        }
        self.client
            .call::<_, WebviewAcknowledgement>("configure-native", settings)
            .await?
            .ensure()
    }
    /// Navigates to the previous history entry, if present.
    pub async fn go_back(&self) -> Result<()> {
        self.acknowledge("go-back", self.controller_request()).await
    }
    /// Navigates to the next history entry, if present.
    pub async fn go_forward(&self) -> Result<()> {
        self.acknowledge("go-forward", self.controller_request())
            .await
    }
    /// Stops the current navigation.
    pub async fn stop_loading(&self) -> Result<()> {
        self.acknowledge("stop-loading", self.controller_request())
            .await
    }
}
