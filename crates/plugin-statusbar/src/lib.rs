//! Status bar (tray icon) bridge plugin facade for openharmony-ability.
//!
//! Provides `StatusBarBridgePlugin` (ID = `ohos.statusbar`, Mode = `AsyncBridge`,
//! REQUIRED_CONTEXTS = `[UiContext]`) and the `StatusBarClient` worker-safe facade.
//!
//! Replaces the legacy `openharmony_ability::statusbar` module's TSFN-based
//! fire-and-forget calls with typed bridge actions. The event channels now
//! live in the status bar consumer's OHOS adapter; this crate only holds injected
//! `Sender<StatusBarClickEvent>` handles (registered by the status bar consumer at startup)
//! so `on_main_thread_event` can forward decoded events to the consumer's local
//! channels without a reverse dependency.

use std::cell::RefCell;
use std::sync::OnceLock;

use crossbeam_channel::Sender;
use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::Unknown;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};
use serde::{Deserialize, Serialize};

// ─── Legacy types (migrated from openharmony-ability::statusbar::types) ───────
// These are plain Rust structs (not #[napi(object)]) used by the status bar consumer to build
// menu/icon data. Icon RGBA bytes live in RefCell<Option<Vec<u8>>> for in-place
// mutation during template-mode monochrome conversion.

#[derive(Default, Clone, Serialize, Deserialize)]
pub struct StatusBarItem {
    pub icons: StatusBarIcon,
    pub quick_operation: QuickOperation,
    pub status_bar_group_menu: Option<Vec<Vec<StatusBarMenuItem>>>,
    pub hover_tips: Option<String>,
}

#[derive(Default, Clone, Serialize, Deserialize)]
pub struct StatusBarIcon {
    #[serde(skip)]
    pub white: RefCell<Option<Vec<u8>>>,
    #[serde(skip)]
    pub black: RefCell<Option<Vec<u8>>>,
    pub size: u32,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct QuickOperation {
    pub ability_name: String,
    pub title: String,
    pub height: u32,
    pub module_name: Option<String>,
    pub loading_status: Option<bool>,
}

impl Default for QuickOperation {
    fn default() -> Self {
        Self {
            ability_name: "EntryAbility".to_string(),
            title: "App".to_string(),
            height: 200,
            module_name: Some("entry".to_string()),
            loading_status: None,
        }
    }
}

// `menu_json` is a `serde_json::to_string` string (not a `#[napi(object)]`), so the
// `#[napi(object)]` snake→camel auto-conversion does NOT apply to these inner keys.
// ArkTS `JSON.parse(menuJson)` yields plain JS objects whose keys must already be
// camelCase (`menuAction`/`subMenu`/`menuCode`/`iconRgba`/`iconWidth`/`iconHeight`/…)
// to match what `StatusbarPlugin.ets`'s `fillMenuItemAbilityName`/`processMenuItemIcons`
// and OHOS `statusBarManager.addToStatusBar` read. The legacy TSFN path
// (`crates/ability/src/statusbar/manager.rs::build_menu_item_object_static`) achieved
// this by hand-writing camelCase `Object::set` keys; the bridge dropped that step, so
// `rename_all` restores the contract here. See spec §7.3.
#[derive(Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusBarMenuItem {
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub menu_code: Option<String>,
    // CRITICAL: `Option::None` serializes to JSON `null` by default, but the OHOS
    // `statusBarManager` contract makes `subMenu`/`menuAction`/`options` *optional*
    // (absent-or-value), NOT null. A present-but-null `subMenu` is not a valid
    // `StatusBarSubMenuItem[]` and statusBarManager logs "not have subMenuItems" at
    // E level per item, then throws 401 "parameter check failed". `skip_serializing_if`
    // makes `None` *absent* (undefined) instead of null. See spec §7.3/§7.5.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sub_menu: Option<Vec<StatusBarSubMenuItem>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub menu_action: Option<StatusBarMenuAction>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub options: Option<StatusBarMenuItemOptions>,
}

#[derive(Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusBarSubMenuItem {
    pub sub_title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub menu_code: Option<String>,
    pub menu_action: StatusBarMenuAction,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub options: Option<StatusBarMenuItemOptions>,
}

#[derive(Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusBarMenuAction {
    pub ability_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub module_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub menu_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notify_only: Option<bool>,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusBarMenuItemOptions {
    #[serde(skip)]
    pub icon: Option<StatusBarItemIcon>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected: Option<bool>,
    #[serde(skip)]
    pub selected_icon: Option<StatusBarItemIcon>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_rgba: Option<Vec<u8>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_height: Option<u32>,
}

impl Clone for StatusBarMenuItemOptions {
    fn clone(&self) -> Self {
        Self {
            icon: None, // cannot clone NAPI objects
            selected: self.selected,
            selected_icon: None,
            icon_rgba: self.icon_rgba.clone(),
            icon_width: self.icon_width,
            icon_height: self.icon_height,
        }
    }
}

#[derive(Default)]
pub struct StatusBarItemIcon {
    pub white: RefCell<Option<napi_ohos::bindgen_prelude::Object<'static>>>,
    pub black: RefCell<Option<napi_ohos::bindgen_prelude::Object<'static>>>,
}

#[derive(Debug, Clone)]
pub enum StatusBarClickEvent {
    IconClick { click_type: String },
    MenuClick { menu_code: String },
}

// ─── Injected event senders (owned by the status bar consumer's OHOS adapter) ──────────────
// The status bar consumer creates the ICON_CLICK_CHANNEL / MENU_CLICK_CHANNEL and registers
// their Senders here at startup via register_icon_click_sender() /
// register_menu_click_sender(). on_main_thread_event forwards decoded events
// through these injected senders, keeping channel ownership in the status bar consumer (the
// consumer) without plugin-statusbar depending on the status bar consumer.

static ICON_CLICK_SENDER: OnceLock<Sender<StatusBarClickEvent>> = OnceLock::new();
static MENU_CLICK_SENDER: OnceLock<Sender<StatusBarClickEvent>> = OnceLock::new();

/// Called by the status bar consumer at startup to register its icon-click channel sender.
/// Idempotent: the first registration wins, later calls are ignored.
pub fn register_icon_click_sender(sender: Sender<StatusBarClickEvent>) {
    let _ = ICON_CLICK_SENDER.set(sender);
}

/// Called by the status bar consumer at startup to register its menu-click channel sender.
/// Idempotent: the first registration wins, later calls are ignored.
pub fn register_menu_click_sender(sender: Sender<StatusBarClickEvent>) {
    let _ = MENU_CLICK_SENDER.set(sender);
}

// ─── Bridge plugin declaration ────────────────────────────────────────────────

pub struct StatusBarBridgePlugin;

impl BridgePlugin for StatusBarBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.statusbar";
    // Matches ArkTS StatusbarPlugin.requires = ["ability"]: addToStatusBar needs a
    // UIAbilityContext, which is available from ability-create onward (before any
    // UI/XComponent mounts). Declaring UiContext here made configurePlugins reject
    // the declaration with "context mismatch: Rust=ui-context, ArkTS=ability",
    // aborting NativeAbility.onCreate before moduleRuntimes was populated — which
    // in turn left windowStageReady=false and froze the app at attach time.
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        match event.name() {
            "icon-click" => {
                let click: StatusBarIconClickEvent = event.decode()?;
                if let Some(sender) = ICON_CLICK_SENDER.get() {
                    let _ = sender.send(StatusBarClickEvent::IconClick {
                        click_type: click.click_type,
                    });
                }
                event.respond(true)
            }
            "menu-click" => {
                let click: StatusBarMenuClickEvent = event.decode()?;
                if let Some(sender) = MENU_CLICK_SENDER.get() {
                    let _ = sender.send(StatusBarClickEvent::MenuClick {
                        menu_code: click.menu_code,
                    });
                }
                event.respond(true)
            }
            other => Err(Error::from_reason(format!(
                "Unsupported ohos.statusbar main-thread event '{other}'"
            ))),
        }
    }
}

// ─── Bridge request/response NAPI types ──────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarAddRequest {
    /// RGBA pixels for the white (light-background) icon. None = no white icon.
    pub white_icon: Option<Vec<u8>>,
    /// RGBA pixels for the black (template/dark-background) icon. None = no black icon.
    pub black_icon: Option<Vec<u8>>,
    pub icon_size: u32,
    pub ability_name: String,
    pub title: String,
    pub height: u32,
    pub module_name: Option<String>,
    pub loading_status: Option<bool>,
    /// Serialized `Vec<Vec<StatusBarMenuItem>>` JSON. None = no menu.
    pub menu_json: Option<String>,
    pub hover_tips: Option<String>,
}

impl_bridge_napi_type!(StatusBarAddRequest, "ohos.statusbar.AddRequest");

impl From<&StatusBarItem> for StatusBarAddRequest {
    fn from(item: &StatusBarItem) -> Self {
        Self {
            white_icon: item.icons.white.borrow().clone(),
            black_icon: item.icons.black.borrow().clone(),
            icon_size: item.icons.size,
            ability_name: item.quick_operation.ability_name.clone(),
            title: item.quick_operation.title.clone(),
            height: item.quick_operation.height,
            module_name: item.quick_operation.module_name.clone(),
            loading_status: item.quick_operation.loading_status,
            menu_json: item
                .status_bar_group_menu
                .as_ref()
                .map(|m| serde_json::to_string(m).unwrap_or_default()),
            hover_tips: item.hover_tips.clone(),
        }
    }
}

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct StatusBarRemoveRequest {}

impl_bridge_napi_type!(StatusBarRemoveRequest, "ohos.statusbar.RemoveRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarUpdateIconRequest {
    pub white_icon: Option<Vec<u8>>,
    pub black_icon: Option<Vec<u8>>,
    pub icon_size: u32,
}

impl_bridge_napi_type!(
    StatusBarUpdateIconRequest,
    "ohos.statusbar.UpdateIconRequest"
);

impl From<StatusBarIcon> for StatusBarUpdateIconRequest {
    fn from(icon: StatusBarIcon) -> Self {
        Self {
            white_icon: icon.white.borrow().clone(),
            black_icon: icon.black.borrow().clone(),
            icon_size: icon.size,
        }
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarUpdateMenuRequest {
    /// Serialized `Vec<Vec<StatusBarMenuItem>>` JSON.
    pub menu_json: String,
}

impl_bridge_napi_type!(
    StatusBarUpdateMenuRequest,
    "ohos.statusbar.UpdateMenuRequest"
);

impl From<&Vec<Vec<StatusBarMenuItem>>> for StatusBarUpdateMenuRequest {
    fn from(menus: &Vec<Vec<StatusBarMenuItem>>) -> Self {
        Self {
            menu_json: serde_json::to_string(menus).unwrap_or_default(),
        }
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarUpdateTipsRequest {
    pub tips: String,
}

impl_bridge_napi_type!(
    StatusBarUpdateTipsRequest,
    "ohos.statusbar.UpdateTipsRequest"
);

/// About-panel metadata carried on [`StatusBarPredefinedRequest`] for the
/// `about` action — mirrors muda's `AboutMetadata` so the ArkTS
/// PredefinedActionExecutor can show the real app info.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct StatusBarAboutMetadata {
    pub name: Option<String>,
    pub version: Option<String>,
    #[napi(js_name = "shortVersion")]
    pub short_version: Option<String>,
    pub authors: Option<Vec<String>>,
    pub comments: Option<String>,
    pub copyright: Option<String>,
    pub license: Option<String>,
    pub website: Option<String>,
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarPredefinedRequest {
    pub action: String,
    /// Metadata for the `about` action; ignored by every other action.
    #[napi(js_name = "aboutMetadata")]
    pub about_metadata: Option<StatusBarAboutMetadata>,
}

impl_bridge_napi_type!(
    StatusBarPredefinedRequest,
    "ohos.statusbar.PredefinedRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(StatusBarAcknowledgement, "ohos.statusbar.Acknowledgement");

impl StatusBarAcknowledgement {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "StatusBar plugin rejected the requested operation",
            ))
        }
    }
}

// ─── Inbound event NAPI types ────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarIconClickEvent {
    /// "leftClick" or "rightClick"
    pub click_type: String,
}

impl_bridge_napi_type!(StatusBarIconClickEvent, "ohos.statusbar.IconClickEvent");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarMenuClickEvent {
    pub menu_code: String,
}

impl_bridge_napi_type!(StatusBarMenuClickEvent, "ohos.statusbar.MenuClickEvent");

// ─── Worker-safe client facade ───────────────────────────────────────────────

/// Worker-safe facade for status bar (tray icon) operations.
///
/// # Thread safety
///
/// All methods are `async` and safe to call from any Rust worker thread or the
/// Chrome_IOThread. **Do not** call these methods (or `block_on` their futures)
/// from an ArkTS/NAPI main-thread callback — that will deadlock the bridge.
#[derive(Clone)]
pub struct StatusBarClient {
    bridge: BridgeRuntime,
}

impl StatusBarClient {
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
            .call_async::<StatusBarBridgePlugin, Request, Response>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await
    }

    /// Creates the tray icon (icon RGBA + quick operation + menu + hover tips).
    pub async fn add(&self, request: StatusBarAddRequest) -> Result<()> {
        self.call::<StatusBarAddRequest, StatusBarAcknowledgement>("add", request)
            .await?
            .ensure()
    }

    /// Removes the tray icon.
    pub async fn remove(&self, request: StatusBarRemoveRequest) -> Result<()> {
        self.call::<StatusBarRemoveRequest, StatusBarAcknowledgement>("remove", request)
            .await?
            .ensure()
    }

    /// Updates the tray icon RGBA pixels.
    pub async fn update_icon(&self, request: StatusBarUpdateIconRequest) -> Result<()> {
        self.call::<StatusBarUpdateIconRequest, StatusBarAcknowledgement>("update-icon", request)
            .await?
            .ensure()
    }

    /// Updates the tray menu JSON.
    pub async fn update_menu(&self, request: StatusBarUpdateMenuRequest) -> Result<()> {
        self.call::<StatusBarUpdateMenuRequest, StatusBarAcknowledgement>("update-menu", request)
            .await?
            .ensure()
    }

    /// Updates the hover tips text.
    pub async fn update_tips(&self, request: StatusBarUpdateTipsRequest) -> Result<()> {
        self.call::<StatusBarUpdateTipsRequest, StatusBarAcknowledgement>("update-tips", request)
            .await?
            .ensure()
    }

    /// Executes a predefined action (copy/cut/paste/quit/minimize/...).
    pub async fn execute_predefined(&self, request: StatusBarPredefinedRequest) -> Result<()> {
        self.call::<StatusBarPredefinedRequest, StatusBarAcknowledgement>(
            "execute-predefined",
            request,
        )
        .await?
        .ensure()
    }
}

/// Extension trait providing the `statusbar()` client on `OpenHarmonyApp`.
pub trait StatusBarExt {
    fn statusbar(&self) -> Result<StatusBarClient>;
}

impl StatusBarExt for OpenHarmonyApp {
    fn statusbar(&self) -> Result<StatusBarClient> {
        StatusBarClient::new(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statusbar_plugin_targets_ability_context() {
        assert_eq!(StatusBarBridgePlugin::ID, "ohos.statusbar");
        assert_eq!(
            StatusBarBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }

    #[test]
    fn add_request_type_name_is_stable() {
        assert_eq!(
            <StatusBarAddRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.statusbar.AddRequest"
        );
        assert_eq!(
            <StatusBarRemoveRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.statusbar.RemoveRequest"
        );
        assert_eq!(
            <StatusBarUpdateIconRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.statusbar.UpdateIconRequest"
        );
        assert_eq!(
            <StatusBarUpdateMenuRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.statusbar.UpdateMenuRequest"
        );
        assert_eq!(
            <StatusBarUpdateTipsRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.statusbar.UpdateTipsRequest"
        );
        assert_eq!(
            <StatusBarPredefinedRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.statusbar.PredefinedRequest"
        );
        assert_eq!(
            <StatusBarAcknowledgement as BridgeNapiType>::TYPE_NAME,
            "ohos.statusbar.Acknowledgement"
        );
    }

    #[test]
    fn event_type_names_are_stable() {
        assert_eq!(
            <StatusBarIconClickEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.statusbar.IconClickEvent"
        );
        assert_eq!(
            <StatusBarMenuClickEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.statusbar.MenuClickEvent"
        );
    }

    #[test]
    fn add_request_from_status_bar_item() {
        let item = StatusBarItem {
            icons: StatusBarIcon {
                white: RefCell::new(Some(vec![1, 2, 3, 4])),
                black: RefCell::new(Some(vec![5, 6, 7, 8])),
                size: 16,
            },
            quick_operation: QuickOperation {
                ability_name: "MainAbility".to_string(),
                title: "Test".to_string(),
                height: 300,
                module_name: Some("entry".to_string()),
                loading_status: Some(true),
            },
            status_bar_group_menu: Some(vec![vec![StatusBarMenuItem {
                title: "Item".to_string(),
                menu_code: Some("0".to_string()),
                sub_menu: None,
                menu_action: None,
                options: None,
            }]]),
            hover_tips: Some("hello".to_string()),
        };
        let req: StatusBarAddRequest = (&item).into();
        assert_eq!(req.white_icon, Some(vec![1, 2, 3, 4]));
        assert_eq!(req.black_icon, Some(vec![5, 6, 7, 8]));
        assert_eq!(req.icon_size, 16);
        assert_eq!(req.ability_name, "MainAbility");
        assert_eq!(req.title, "Test");
        assert_eq!(req.height, 300);
        assert_eq!(req.module_name, Some("entry".to_string()));
        assert_eq!(req.loading_status, Some(true));
        assert!(req.menu_json.is_some());
        assert_eq!(req.hover_tips, Some("hello".to_string()));
    }

    #[test]
    fn update_icon_request_from_status_bar_icon() {
        let icon = StatusBarIcon {
            white: RefCell::new(Some(vec![255; 64])),
            black: RefCell::new(None),
            size: 4,
        };
        let req: StatusBarUpdateIconRequest = icon.into();
        assert_eq!(req.white_icon, Some(vec![255; 64]));
        assert_eq!(req.black_icon, None);
        assert_eq!(req.icon_size, 4);
    }

    #[test]
    fn update_menu_request_from_groups() {
        let groups: Vec<Vec<StatusBarMenuItem>> = vec![vec![StatusBarMenuItem {
            title: "Quit".to_string(),
            menu_code: Some("0".to_string()),
            sub_menu: None,
            menu_action: None,
            options: None,
        }]];
        let req: StatusBarUpdateMenuRequest = (&groups).into();
        assert!(req.menu_json.contains("Quit"));
    }

    #[test]
    fn acknowledgement_ensure_rejects_false() {
        let ack = StatusBarAcknowledgement { accepted: false };
        assert!(ack.ensure().is_err());

        let ack = StatusBarAcknowledgement { accepted: true };
        assert!(ack.ensure().is_ok());
    }

    #[test]
    fn registered_sender_forwards_icon_click() {
        let (tx, rx) = crossbeam_channel::unbounded::<StatusBarClickEvent>();
        register_icon_click_sender(tx);
        let sender = ICON_CLICK_SENDER.get().expect("sender registered");
        sender
            .send(StatusBarClickEvent::IconClick {
                click_type: "leftClick".to_string(),
            })
            .unwrap();
        let event = rx.recv().unwrap();
        match event {
            StatusBarClickEvent::IconClick { click_type } => {
                assert_eq!(click_type, "leftClick");
            }
            _ => panic!("expected IconClick"),
        }
    }
}
