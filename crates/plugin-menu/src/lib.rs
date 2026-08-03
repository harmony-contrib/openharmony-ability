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

use std::{
    future::Future,
    pin::Pin,
};

use crossbeam_channel::{unbounded, Receiver, Sender};
use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::Unknown,
    Error, Result,
};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgePlugin, OpenHarmonyApp,
};

pub struct MenuBridgePlugin;

impl BridgePlugin for MenuBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.menu";
    const VERSION: u32 = 1;
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];

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
                let _ = MENU_EVENT_TX.send(request.id);
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

static MENU_EVENT_CHANNEL: std::sync::LazyLock<(Sender<String>, Receiver<String>)> =
    std::sync::LazyLock::new(unbounded);

static MENU_EVENT_TX: std::sync::LazyLock<Sender<String>> =
    std::sync::LazyLock::new(|| MENU_EVENT_CHANNEL.0.clone());

/// Menu item kinds, mirroring muda/tauri menu semantics.
pub mod item_kind {
    pub const NORMAL: &str = "item";
    pub const SUBMENU: &str = "submenu";
    pub const SEPARATOR: &str = "separator";
    pub const PREDEFINED: &str = "predefined";
    pub const ABOUT: &str = "about";
}

/// Optional application metadata for the "about" menu item.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AboutMetadataData {
    pub name: Option<String>,
    pub version: Option<String>,
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

    fn validate(&self) -> Result<()> {
        if self.id.trim().is_empty() {
            return Err(Error::from_reason("menu item id must not be empty"));
        }
        if let Some(items) = self.submenu_items.as_ref() {
            for item in items {
                item.validate()?;
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
        for item in &self.items {
            item.validate()?;
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
        for item in &self.items {
            item.validate()?;
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

    /// Receives menu ids clicked in ArkTS UI. Pairs with [`Self::set_menubar`] item ids.
    fn menu_event_receiver() -> &'static Receiver<String>;
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
        let window_id = window_id.into();
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<MenuBridgePlugin, MenuVisibilityRequest, MenuAcknowledgement>(
                    "set-menubar-visible",
                    MenuVisibilityRequest {
                        window_id,
                        visible,
                    },
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }

    fn menu_event_receiver() -> &'static Receiver<String> {
        &MENU_EVENT_CHANNEL.1
    }
}

#[cfg(test)]
mod tests {
    use super::{item_kind, MenuBarRequest, MenuItemData, MenuPopupRequest};
    use openharmony_ability::BridgeNapiType;

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
        let file = MenuItemData::new("file", item_kind::SUBMENU).text("File").submenu(vec![
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
    }
}
