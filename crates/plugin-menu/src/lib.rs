//! Menu bridge plugin facade for openharmony-ability.
//!
//! Provides `MenuBridgePlugin` (ID = `ohos.menu`, Mode = `AsyncBridge`,
//! REQUIRED_CONTEXTS = `[UiContext]`) and the `MenuClient` worker-safe facade.
//!
//! Replaces the legacy `openharmony_ability::menu` module's TSFN/channel-based
//! transport with typed bridge actions. The event channel now lives in the menu consumer's
//! OHOS adapter; this crate only holds an injected `Sender<String>` (registered
//! by the menu consumer at startup) so `on_main_thread_event` can forward decoded menu_id
//! strings to the consumer's `MENU_EVENT_CHANNEL` without a reverse dependency.

use std::collections::HashMap;
use std::sync::{LazyLock, OnceLock, RwLock};

use crossbeam_channel::Sender;
use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::Unknown;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};
use serde::{Deserialize, Serialize};

// ─── Menu data types (migrated from openharmony-ability::menu::types) ────────
// These #[napi(object)] structs are used by the menu consumer for JSON serialization.
// The serde attributes ensure the JSON format is identical to the legacy module,
// so the ArkTS side (which consumes the JSON) requires no changes.

#[napi(object)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AboutMetadataData {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "shortVersion")]
    #[napi(js_name = "shortVersion")]
    pub short_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub authors: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub comments: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub copyright: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub website: Option<String>,
}

#[napi(object)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MenuItemData {
    pub id: String,
    #[napi(js_name = "type")]
    #[serde(rename = "type")]
    pub item_type: String,
    pub text: Option<String>,
    pub enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accelerator: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "predefinedType")]
    pub predefined_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checked: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "nativeIcon")]
    #[napi(js_name = "nativeIcon")]
    pub native_icon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[napi(js_name = "submenuItems")]
    #[serde(rename = "submenuItems")]
    pub submenu_items: Option<Vec<MenuItemData>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "aboutMetadata")]
    #[napi(js_name = "aboutMetadata")]
    pub about_metadata: Option<AboutMetadataData>,
}

// ─── Injected event sender (owned by the menu consumer's OHOS adapter) ───────────────────
// The menu consumer creates the MENU_EVENT_CHANNEL and registers its Sender here at startup
// via `register_menu_event_sender()`. `on_main_thread_event` then forwards
// decoded menu_id strings through the injected sender. This keeps the channel
// ownership in the menu consumer (the consumer) without plugin-menu depending on the menu consumer.

static MENU_EVENT_SENDER: OnceLock<Sender<String>> = OnceLock::new();

/// Called by the menu consumer at startup to register its menu event channel sender.
/// Idempotent: the first registration wins, later calls are ignored.
pub fn register_menu_event_sender(sender: Sender<String>) {
    let _ = MENU_EVENT_SENDER.set(sender);
}

// ─── Per-window visibility / content state cache ──────────────────────────────
// Tracks whether the menubar is visible and whether it has content, per window.
// `is_menubar_visible()` returns true only when both are true (visible AND has content).

static MENUBAR_VISIBLE: LazyLock<RwLock<HashMap<String, bool>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));
static MENU_HAS_CONTENT: LazyLock<RwLock<HashMap<String, bool>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

// ─── Bridge plugin declaration ────────────────────────────────────────────────

pub struct MenuBridgePlugin;

impl BridgePlugin for MenuBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.menu";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::UiContext];

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        match event.name() {
            "menu-click" => {
                let click: MenuClickEvent = event.decode()?;
                if let Some(sender) = MENU_EVENT_SENDER.get() {
                    let _ = sender.send(click.menu_id);
                }
                event.respond(true)
            }
            other => Err(Error::from_reason(format!(
                "Unsupported ohos.menu main-thread event '{other}'"
            ))),
        }
    }
}

// ─── Bridge request/response NAPI types ──────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuSetMenubarRequest {
    /// Serialized `Vec<MenuItemData>` JSON.
    pub json_data: String,
    pub window_id: String,
}

impl_bridge_napi_type!(MenuSetMenubarRequest, "ohos.menu.SetMenubarRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuPopupRequest {
    /// Serialized `Vec<MenuItemData>` JSON.
    pub json_data: String,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub window_id: String,
}

impl_bridge_napi_type!(MenuPopupRequest, "ohos.menu.PopupRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuSetVisibleRequest {
    pub visible: bool,
    pub window_id: String,
}

impl_bridge_napi_type!(MenuSetVisibleRequest, "ohos.menu.SetVisibleRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuPredefinedRequest {
    pub action: String,
    pub window_id: Option<String>,
}

impl_bridge_napi_type!(MenuPredefinedRequest, "ohos.menu.PredefinedRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(MenuAcknowledgement, "ohos.menu.Acknowledgement");

impl MenuAcknowledgement {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "Menu plugin rejected the requested operation",
            ))
        }
    }
}

// ─── Inbound event NAPI type ─────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuClickEvent {
    pub menu_id: String,
    pub window_id: Option<String>,
}

impl_bridge_napi_type!(MenuClickEvent, "ohos.menu.MenuClickEvent");

// ─── Worker-safe client facade ───────────────────────────────────────────────

/// Worker-safe facade for menu bar and popup menu operations.
///
/// # Thread safety
///
/// All methods are `async` and safe to call from any Rust worker thread or the
/// Chrome_IOThread. **Do not** call these methods (or `block_on` their futures)
/// from an ArkTS/NAPI main-thread callback — that will deadlock the bridge.
#[derive(Clone)]
pub struct MenuClient {
    bridge: BridgeRuntime,
}

impl MenuClient {
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }

    async fn call<Request, Response>(&self, action: &str, request: Request) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.bridge
            .call_async::<MenuBridgePlugin, Request, Response>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await
    }

    /// Sets the menu bar JSON for a window.
    pub async fn set_menubar(&self, request: MenuSetMenubarRequest) -> Result<()> {
        let window_id = request.window_id.clone();
        let has_content = request.json_data != "[]";
        self.call::<MenuSetMenubarRequest, MenuAcknowledgement>("set-menubar", request)
            .await?
            .ensure()?;
        // Update content cache after successful bridge call.
        if let Ok(mut cache) = MENU_HAS_CONTENT.write() {
            cache.insert(window_id, has_content);
        }
        Ok(())
    }

    /// Convenience wrapper: sets the menu bar JSON for a window from a raw JSON string.
    /// Maps to the existing `set-menubar` action and updates the content cache.
    pub async fn set_menu_json(&self, json_data: String, window_id: String) -> Result<()> {
        self.set_menubar(MenuSetMenubarRequest {
            json_data,
            window_id,
        })
        .await
    }

    /// Pops up a context menu at the given coordinates.
    pub async fn popup(&self, request: MenuPopupRequest) -> Result<()> {
        self.call::<MenuPopupRequest, MenuAcknowledgement>("popup", request)
            .await?
            .ensure()
    }

    /// Sets the menu bar visibility for a window.
    pub async fn set_menubar_visible(&self, request: MenuSetVisibleRequest) -> Result<()> {
        let window_id = request.window_id.clone();
        let visible = request.visible;
        self.call::<MenuSetVisibleRequest, MenuAcknowledgement>("set-menubar-visible", request)
            .await?
            .ensure()?;
        // Update visibility cache after successful bridge call.
        if let Ok(mut cache) = MENUBAR_VISIBLE.write() {
            cache.insert(window_id, visible);
        }
        Ok(())
    }

    /// Returns whether the menu bar is visible for a window.
    ///
    /// Synchronous: reads the per-window visibility and content caches.
    /// Returns `true` only when both the menubar is visible AND it has content.
    pub fn is_menubar_visible(&self, window_id: &str) -> bool {
        let visible = MENUBAR_VISIBLE
            .read()
            .map(|cache| cache.get(window_id).copied().unwrap_or(true))
            .unwrap_or(true);
        let has_content = MENU_HAS_CONTENT
            .read()
            .map(|cache| cache.get(window_id).copied().unwrap_or(true))
            .unwrap_or(true);
        visible && has_content
    }

    /// Executes a predefined action (copy/cut/paste/quit/minimize/...).
    pub async fn execute_predefined(&self, request: MenuPredefinedRequest) -> Result<()> {
        self.call::<MenuPredefinedRequest, MenuAcknowledgement>("execute-predefined", request)
            .await?
            .ensure()
    }
}

/// Extension trait providing the `menu()` client on `OpenHarmonyApp`.
pub trait MenuExt {
    fn menu(&self) -> Result<MenuClient>;
}

impl MenuExt for OpenHarmonyApp {
    fn menu(&self) -> Result<MenuClient> {
        MenuClient::new(self)
    }
}

#[cfg(all(test, target_env = "ohos"))]
mod tests {
    use super::*;

    #[test]
    fn menu_plugin_targets_ui_context() {
        assert_eq!(MenuBridgePlugin::ID, "ohos.menu");
        assert_eq!(
            MenuBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::UiContext]
        );
    }

    #[test]
    fn request_type_names_are_stable() {
        assert_eq!(
            <MenuSetMenubarRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.menu.SetMenubarRequest"
        );
        assert_eq!(
            <MenuPopupRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.menu.PopupRequest"
        );
        assert_eq!(
            <MenuSetVisibleRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.menu.SetVisibleRequest"
        );
        assert_eq!(
            <MenuPredefinedRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.menu.PredefinedRequest"
        );
        assert_eq!(
            <MenuAcknowledgement as BridgeNapiType>::TYPE_NAME,
            "ohos.menu.Acknowledgement"
        );
        assert_eq!(
            <MenuClickEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.menu.MenuClickEvent"
        );
    }

    #[test]
    fn register_menu_event_sender_forwards_to_injected_sender() {
        let (tx, rx) = crossbeam_channel::unbounded::<String>();
        register_menu_event_sender(tx.clone());
        // on_main_thread_event path: use the registered sender directly.
        let sender = MENU_EVENT_SENDER.get().expect("sender registered");
        sender.send("test_id".to_string()).unwrap();
        assert_eq!(rx.recv().unwrap(), "test_id");
    }

    #[test]
    fn menu_item_data_serde_roundtrip() {
        let data = MenuItemData {
            id: "item1".to_string(),
            item_type: "item".to_string(),
            text: Some("Open".to_string()),
            enabled: Some(true),
            accelerator: Some("Ctrl+O".to_string()),
            predefined_type: None,
            checked: None,
            icon: None,
            native_icon: None,
            submenu_items: None,
            about_metadata: None,
        };
        let json = serde_json::to_string(&data).unwrap();
        let parsed: MenuItemData = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.id, data.id);
        assert_eq!(parsed.item_type, data.item_type);
        assert_eq!(parsed.text, data.text);
        assert_eq!(parsed.accelerator, data.accelerator);
    }

    #[test]
    fn menu_item_data_serde_skip_none() {
        let data = MenuItemData {
            id: "minimal".to_string(),
            item_type: "item".to_string(),
            text: Some("Click".to_string()),
            enabled: Some(true),
            accelerator: None,
            predefined_type: None,
            checked: None,
            icon: None,
            native_icon: None,
            submenu_items: None,
            about_metadata: None,
        };
        let json = serde_json::to_string(&data).unwrap();
        assert!(!json.contains("\"accelerator\""));
        assert!(!json.contains("\"predefinedType\""));
        assert!(!json.contains("\"checked\""));
        assert!(!json.contains("\"icon\""));
        assert!(!json.contains("\"submenuItems\""));
        assert!(!json.contains("\"aboutMetadata\""));
    }

    #[test]
    fn about_metadata_serde_roundtrip() {
        let meta = AboutMetadataData {
            name: Some("App".to_string()),
            version: Some("2.0".to_string()),
            short_version: Some("2".to_string()),
            authors: Some(vec!["A".to_string(), "B".to_string()]),
            comments: Some("test".to_string()),
            copyright: Some("C".to_string()),
            license: Some("MIT".to_string()),
            website: Some("https://example.com".to_string()),
        };
        let json = serde_json::to_string(&meta).unwrap();
        let parsed: AboutMetadataData = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.name, meta.name);
        assert_eq!(parsed.version, meta.version);
        assert_eq!(parsed.short_version, meta.short_version);
        assert_eq!(parsed.authors, meta.authors);
        assert_eq!(parsed.website, meta.website);
    }
}
