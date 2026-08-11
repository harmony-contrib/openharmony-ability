//! Menu capability plugin facade (menubar + context popup).
//!
//! Ports the former `crates/ability/src/menu/` capability into the pluginized bridge model.
//!
//! Direction of data flow:
//! - Rust (muda) builds a menu tree and calls `set_menubar` / `popup`; the async plugin
//!   delivers it to ArkTS, which renders the `MenuBarComponent` / popup UI.
//! - ArkTS reports clicks through the named main-thread event (`menu-click`); the Rust facade
//!   forwards them into [`MenuExt::menu_event_receiver`] for muda-style listeners.
//!
//! Menu items are structured, named N-API values (`ohos.menu.MenuItemData`), never JSON.

use std::{collections::BTreeSet, future::Future, pin::Pin};

use crossbeam_channel::{unbounded, Receiver, Sender};
use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgePlugin, OpenHarmonyApp,
};

pub struct MenuBridgePlugin;

impl BridgePlugin for MenuBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.menu";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] = &[];

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        match event.name() {
            "menu-click" => {
                let request = event.decode::<MenuClickRequest>()?;
                if request.id.trim().is_empty() {
                    return Err(Error::from_reason(
                        "menu-click event requires a non-empty menu id",
                    ));
                }
                if request
                    .window_id
                    .as_ref()
                    .is_some_and(|window_id| window_id.trim().is_empty())
                {
                    return Err(Error::from_reason(
                        "menu-click event window id must not be empty when provided",
                    ));
                }
                let _ = MENU_EVENT_TX.send(MenuEvent {
                    id: request.id,
                    window_id: request.window_id,
                });
                event.respond(MenuClickResponse { accepted: true })
            }
            _ => Err(Error::from_reason(format!(
                "Menu plugin does not support main-thread event '{}'",
                event.name()
            ))),
        }
    }
}

/// ArkTS → Rust menu click request (named N-API main-thread event).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuClickRequest {
    pub id: String,
    pub window_id: Option<String>,
}

impl_bridge_napi_type!(MenuClickRequest, "ohos.menu.ClickRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuClickResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(MenuClickResponse, "ohos.menu.ClickResponse");

/// Rust-owned menu event. `window_id` preserves the originating business window for multi-window
/// plugin instances; it is not a native module routing key.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MenuEvent {
    pub id: String,
    pub window_id: Option<String>,
}

static MENU_EVENT_CHANNEL: std::sync::LazyLock<(Sender<MenuEvent>, Receiver<MenuEvent>)> =
    std::sync::LazyLock::new(unbounded);

static MENU_EVENT_TX: std::sync::LazyLock<Sender<MenuEvent>> =
    std::sync::LazyLock::new(|| MENU_EVENT_CHANNEL.0.clone());

/// Menu item kinds, mirroring muda/tauri menu semantics.
pub mod item_kind {
    pub const NORMAL: &str = "item";
    pub const SUBMENU: &str = "submenu";
    pub const SEPARATOR: &str = "separator";
    pub const PREDEFINED: &str = "predefined";
    pub const CHECK: &str = "check";
    pub const ICON: &str = "icon";
    pub const ABOUT: &str = "about";
}

const MAX_MENU_ITEMS: usize = 512;
const MAX_MENU_DEPTH: usize = 16;

/// Optional application metadata for the "about" menu item.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AboutMetadataData {
    pub name: Option<String>,
    pub version: Option<String>,
    pub short_version: Option<String>,
    pub authors: Option<Vec<String>>,
    pub comments: Option<String>,
    pub copyright: Option<String>,
    pub license: Option<String>,
    pub website: Option<String>,
}

impl_bridge_napi_type!(AboutMetadataData, "ohos.menu.AboutMetadata");

/// One recursive menu entry. `submenu_items` nests child entries.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuItemData {
    pub id: String,
    /// One of [`item_kind`] constants.
    pub item_type: String,
    pub text: Option<String>,
    pub enabled: Option<bool>,
    pub accelerator: Option<String>,
    /// One of the predefined action names, e.g. `copy`, `paste`, `quit`, `minimize`.
    pub predefined_type: Option<String>,
    pub checked: Option<bool>,
    pub icon: Option<String>,
    pub native_icon: Option<String>,
    pub submenu_items: Option<Vec<MenuItemData>>,
    pub about_metadata: Option<AboutMetadataData>,
}

impl_bridge_napi_type!(MenuItemData, "ohos.menu.MenuItemData");

impl MenuItemData {
    pub fn new(id: impl Into<String>, item_type: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            item_type: item_type.into(),
            text: None,
            enabled: None,
            accelerator: None,
            predefined_type: None,
            checked: None,
            icon: None,
            native_icon: None,
            submenu_items: None,
            about_metadata: None,
        }
    }

    pub fn text(mut self, text: impl Into<String>) -> Self {
        self.text = Some(text.into());
        self
    }

    pub fn enabled(mut self, enabled: bool) -> Self {
        self.enabled = Some(enabled);
        self
    }

    pub fn accelerator(mut self, accelerator: impl Into<String>) -> Self {
        self.accelerator = Some(accelerator.into());
        self
    }

    pub fn predefined(mut self, predefined_type: impl Into<String>) -> Self {
        self.predefined_type = Some(predefined_type.into());
        self
    }

    pub fn checked(mut self, checked: bool) -> Self {
        self.checked = Some(checked);
        self
    }

    pub fn submenu(mut self, items: Vec<MenuItemData>) -> Self {
        self.submenu_items = Some(items);
        self
    }

    fn validate(
        &self,
        ids: &mut BTreeSet<String>,
        item_count: &mut usize,
        depth: usize,
    ) -> Result<()> {
        if depth > MAX_MENU_DEPTH {
            return Err(Error::from_reason(format!(
                "menu tree exceeds the {MAX_MENU_DEPTH} level depth limit"
            )));
        }
        *item_count = item_count
            .checked_add(1)
            .ok_or_else(|| Error::from_reason("menu item count overflow"))?;
        if *item_count > MAX_MENU_ITEMS {
            return Err(Error::from_reason(format!(
                "menu tree exceeds the {MAX_MENU_ITEMS} item limit"
            )));
        }
        if self.id.trim().is_empty() {
            return Err(Error::from_reason("menu item id must not be empty"));
        }
        if !matches!(
            self.item_type.as_str(),
            item_kind::NORMAL
                | item_kind::SUBMENU
                | item_kind::SEPARATOR
                | item_kind::PREDEFINED
                | item_kind::CHECK
                | item_kind::ICON
                | item_kind::ABOUT
        ) {
            return Err(Error::from_reason(format!(
                "unsupported menu item type '{}'",
                self.item_type
            )));
        }
        if !ids.insert(self.id.clone()) {
            return Err(Error::from_reason(format!(
                "menu item id '{}' is duplicated",
                self.id
            )));
        }
        if let Some(items) = self.submenu_items.as_ref() {
            for item in items {
                item.validate(ids, item_count, depth + 1)?;
            }
        }
        Ok(())
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuBarRequest {
    pub window_id: String,
    pub items: Vec<MenuItemData>,
}

impl_bridge_napi_type!(MenuBarRequest, "ohos.menu.MenuBarRequest");

impl MenuBarRequest {
    fn validate(&self) -> Result<()> {
        if self.window_id.trim().is_empty() {
            return Err(Error::from_reason("menu windowId must not be empty"));
        }
        let mut ids = BTreeSet::new();
        let mut item_count = 0;
        for item in &self.items {
            item.validate(&mut ids, &mut item_count, 1)?;
        }
        Ok(())
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuPopupRequest {
    pub window_id: String,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub items: Vec<MenuItemData>,
}

impl_bridge_napi_type!(MenuPopupRequest, "ohos.menu.PopupRequest");

impl MenuPopupRequest {
    fn validate(&self) -> Result<()> {
        if self.window_id.trim().is_empty() {
            return Err(Error::from_reason("menu windowId must not be empty"));
        }
        if self.items.is_empty() {
            return Err(Error::from_reason("popup menu requires at least one item"));
        }
        if self.x.is_some_and(|value| !value.is_finite())
            || self.y.is_some_and(|value| !value.is_finite())
        {
            return Err(Error::from_reason(
                "popup menu coordinates must be finite numbers",
            ));
        }
        let mut ids = BTreeSet::new();
        let mut item_count = 0;
        for item in &self.items {
            item.validate(&mut ids, &mut item_count, 1)?;
        }
        Ok(())
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MenuVisibilityRequest {
    pub window_id: String,
    pub visible: bool,
}

impl_bridge_napi_type!(MenuVisibilityRequest, "ohos.menu.VisibilityRequest");

impl MenuVisibilityRequest {
    fn validate(&self) -> Result<()> {
        if self.window_id.trim().is_empty() {
            return Err(Error::from_reason("menu windowId must not be empty"));
        }
        Ok(())
    }
}

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

/// Extension trait supplied by the capability package, never by `openharmony-ability` core.
pub trait MenuExt {
    /// Sets the per-window menubar content. Empty `items` hides the menubar.
    fn set_menubar(
        &self,
        window_id: impl Into<String>,
        items: Vec<MenuItemData>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    /// Shows a context popup menu at optional screen coordinates.
    fn popup(
        &self,
        window_id: impl Into<String>,
        x: Option<f64>,
        y: Option<f64>,
        items: Vec<MenuItemData>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    /// Sets per-window menubar visibility.
    fn set_menubar_visible(
        &self,
        window_id: impl Into<String>,
        visible: bool,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    /// Receives menu ids and their originating business window ids from ArkTS UI.
    fn menu_event_receiver() -> &'static Receiver<MenuEvent>;
}

impl MenuExt for OpenHarmonyApp {
    fn set_menubar(
        &self,
        window_id: impl Into<String>,
        items: Vec<MenuItemData>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let request = MenuBarRequest {
            window_id: window_id.into(),
            items,
        };
        if let Err(error) = request.validate() {
            return Box::pin(async move { Err(error) });
        }
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<MenuBridgePlugin, MenuBarRequest, MenuAcknowledgement>(
                    "set-menubar",
                    request,
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }

    fn popup(
        &self,
        window_id: impl Into<String>,
        x: Option<f64>,
        y: Option<f64>,
        items: Vec<MenuItemData>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let request = MenuPopupRequest {
            window_id: window_id.into(),
            x,
            y,
            items,
        };
        if let Err(error) = request.validate() {
            return Box::pin(async move { Err(error) });
        }
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<MenuBridgePlugin, MenuPopupRequest, MenuAcknowledgement>(
                    "popup",
                    request,
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }

    fn set_menubar_visible(
        &self,
        window_id: impl Into<String>,
        visible: bool,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let request = MenuVisibilityRequest {
            window_id: window_id.into(),
            visible,
        };
        if let Err(error) = request.validate() {
            return Box::pin(async move { Err(error) });
        }
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<MenuBridgePlugin, MenuVisibilityRequest, MenuAcknowledgement>(
                    "set-menubar-visible",
                    request,
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }

    fn menu_event_receiver() -> &'static Receiver<MenuEvent> {
        &MENU_EVENT_CHANNEL.1
    }
}

#[cfg(test)]
mod tests {
    use super::{
        item_kind, MenuBarRequest, MenuBridgePlugin, MenuEvent, MenuItemData, MenuPopupRequest,
        MenuVisibilityRequest, MAX_MENU_DEPTH,
    };
    use openharmony_ability::{BridgeNapiType, BridgePlugin};

    #[test]
    fn menu_uses_stable_named_napi_contracts() {
        assert_eq!(
            <MenuItemData as BridgeNapiType>::TYPE_NAME,
            "ohos.menu.MenuItemData"
        );
        assert_eq!(
            <MenuBarRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.menu.MenuBarRequest"
        );
        assert_eq!(
            <MenuPopupRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.menu.PopupRequest"
        );
    }

    #[test]
    fn menu_item_builds_recursive_tree() {
        let file = MenuItemData::new("file", item_kind::SUBMENU)
            .text("File")
            .submenu(vec![
                MenuItemData::new("file.open", item_kind::NORMAL).text("Open"),
                MenuItemData::new("file.sep", item_kind::SEPARATOR),
                MenuItemData::new("file.quit", item_kind::PREDEFINED)
                    .predefined("quit")
                    .accelerator("Ctrl+Q"),
            ]);
        let request = MenuBarRequest {
            window_id: "main".to_owned(),
            items: vec![file],
        };
        assert!(request.validate().is_ok());
        let empty_window = MenuBarRequest {
            window_id: " ".to_owned(),
            items: vec![],
        };
        assert!(empty_window.validate().is_err());
        assert!(MenuBridgePlugin::REQUIRED_CONTEXTS.is_empty());

        let duplicated = MenuBarRequest {
            window_id: "main".to_owned(),
            items: vec![
                MenuItemData::new("same", item_kind::NORMAL),
                MenuItemData::new("same", item_kind::NORMAL),
            ],
        };
        assert!(duplicated.validate().is_err());

        let unsupported = MenuBarRequest {
            window_id: "main".to_owned(),
            items: vec![MenuItemData::new("unknown", "custom")],
        };
        assert!(unsupported.validate().is_err());

        let mut nested = MenuItemData::new("leaf", item_kind::NORMAL);
        for depth in 0..MAX_MENU_DEPTH {
            nested = MenuItemData::new(format!("nested.{depth}"), item_kind::SUBMENU)
                .submenu(vec![nested]);
        }
        assert!(MenuBarRequest {
            window_id: "main".to_owned(),
            items: vec![nested],
        }
        .validate()
        .is_err());

        let event = MenuEvent {
            id: "open".to_owned(),
            window_id: Some("secondary".to_owned()),
        };
        assert_eq!(event.window_id.as_deref(), Some("secondary"));
    }

    #[test]
    fn popup_requires_items() {
        let request = MenuPopupRequest {
            window_id: "main".to_owned(),
            x: Some(10.0),
            y: Some(20.0),
            items: vec![],
        };
        assert!(request.validate().is_err());

        let non_finite = MenuPopupRequest {
            window_id: "main".to_owned(),
            x: Some(f64::NAN),
            y: None,
            items: vec![MenuItemData::new("open", item_kind::NORMAL)],
        };
        assert!(non_finite.validate().is_err());

        let visibility = MenuVisibilityRequest {
            window_id: " ".to_owned(),
            visible: true,
        };
        assert!(visibility.validate().is_err());
    }
}
