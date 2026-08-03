//! System tray / status bar capability plugin facade.
//!
//! Ports the former `crates/ability/src/statusbar/` capability into the pluginized bridge
//! model. Rust (tray-icon style callers) build a [`StatusBarItemData`] and call the add /
//! update actions; ArkTS renders the item. Clicks flow back through the bounded event port
//! into [`StatusBarExt::icon_click_receiver`] / [`StatusBarExt::menu_click_receiver`].

use std::{future::Future, pin::Pin};

use crossbeam_channel::{unbounded, Receiver, Sender};
use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgePlugin, OpenHarmonyApp,
};

pub struct StatusBarBridgePlugin;

impl BridgePlugin for StatusBarBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.statusbar";
    const VERSION: u32 = 1;
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        match event.name() {
            "icon-click" => {
                let request = event.decode::<StatusBarClickRequest>()?;
                if request.click_type.trim().is_empty() {
                    return Err(Error::from_reason(
                        "statusbar icon-click event requires a non-empty click type",
                    ));
                }
                let _ = ICON_CLICK_TX.send(request.click_type);
                event.respond(StatusBarClickResponse { accepted: true })
            }
            "menu-click" => {
                let request = event.decode::<StatusBarMenuClickRequest>()?;
                if request.menu_code.trim().is_empty() {
                    return Err(Error::from_reason(
                        "statusbar menu-click event requires a non-empty menu code",
                    ));
                }
                let _ = MENU_CLICK_TX.send(request.menu_code);
                event.respond(StatusBarClickResponse { accepted: true })
            }
            _ => Err(Error::from_reason(format!(
                "Status bar plugin does not support main-thread event '{}'",
                event.name()
            ))),
        }
    }
}

/// ArkTS → Rust tray icon click request (named N-API main-thread event).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarClickRequest {
    pub click_type: String,
}

impl_bridge_napi_type!(StatusBarClickRequest, "ohos.statusbar.ClickRequest");

/// ArkTS → Rust tray menu click request (named N-API main-thread event).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarMenuClickRequest {
    pub menu_code: String,
}

impl_bridge_napi_type!(StatusBarMenuClickRequest, "ohos.statusbar.MenuClickRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarClickResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(StatusBarClickResponse, "ohos.statusbar.ClickResponse");

static ICON_CLICK_CHANNEL: std::sync::LazyLock<(Sender<String>, Receiver<String>)> =
    std::sync::LazyLock::new(unbounded);

static MENU_CLICK_CHANNEL: std::sync::LazyLock<(Sender<String>, Receiver<String>)> =
    std::sync::LazyLock::new(unbounded);

static ICON_CLICK_TX: std::sync::LazyLock<Sender<String>> =
    std::sync::LazyLock::new(|| ICON_CLICK_CHANNEL.0.clone());

static MENU_CLICK_TX: std::sync::LazyLock<Sender<String>> =
    std::sync::LazyLock::new(|| MENU_CLICK_CHANNEL.0.clone());

const MAX_GROUP_MENU_ITEMS: usize = 20;
const MAX_SUB_MENU_ITEMS: usize = 20;
const MAX_HOVER_TIPS_LEN: usize = 128;

/// Quick-operation card shown when the tray item is hovered.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct QuickOperationData {
    pub ability_name: String,
    pub title: String,
    pub height: u32,
    pub module_name: Option<String>,
    pub loading_status: Option<bool>,
}

impl_bridge_napi_type!(QuickOperationData, "ohos.statusbar.QuickOperation");

impl Default for QuickOperationData {
    fn default() -> Self {
        Self {
            ability_name: "EntryAbility".to_owned(),
            title: "App".to_owned(),
            height: 200,
            module_name: Some("entry".to_owned()),
            loading_status: None,
        }
    }
}

/// Menu action launched when a tray menu item is activated.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarMenuActionData {
    pub ability_name: String,
    pub module_name: Option<String>,
    pub menu_code: Option<String>,
    pub notify_only: Option<bool>,
}

impl_bridge_napi_type!(StatusBarMenuActionData, "ohos.statusbar.MenuAction");

/// One tray sub-menu entry.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarSubMenuItemData {
    pub sub_title: String,
    pub menu_code: Option<String>,
    pub menu_action: StatusBarMenuActionData,
    pub selected: Option<bool>,
}

impl_bridge_napi_type!(StatusBarSubMenuItemData, "ohos.statusbar.SubMenuItem");

/// One tray menu entry with an optional sub-menu group.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarMenuItemData {
    pub title: String,
    pub menu_code: Option<String>,
    pub sub_menu: Option<Vec<StatusBarSubMenuItemData>>,
    pub menu_action: Option<StatusBarMenuActionData>,
    pub selected: Option<bool>,
    pub icon_rgba: Option<Vec<u8>>,
    pub icon_width: Option<u32>,
    pub icon_height: Option<u32>,
}

impl_bridge_napi_type!(StatusBarMenuItemData, "ohos.statusbar.MenuItem");

impl StatusBarMenuItemData {
    fn validate(&self) -> Result<()> {
        if self.title.trim().is_empty() {
            return Err(Error::from_reason(
                "status bar menu item title must not be empty",
            ));
        }
        if let Some(sub_menu) = self.sub_menu.as_ref() {
            if sub_menu.len() > MAX_SUB_MENU_ITEMS {
                return Err(Error::from_reason(format!(
                    "status bar sub menu exceeds the {MAX_SUB_MENU_ITEMS} item limit"
                )));
            }
        }
        Ok(())
    }
}

/// One tray icon with optional white/black RGBA pixel variants.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarIconData {
    pub white_rgba: Option<Vec<u8>>,
    pub black_rgba: Option<Vec<u8>>,
    pub size: u32,
}

impl_bridge_napi_type!(StatusBarIconData, "ohos.statusbar.IconData");

/// Full tray item description.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarItemData {
    pub icons: StatusBarIconData,
    pub quick_operation: QuickOperationData,
    pub status_bar_group_menu: Option<Vec<Vec<StatusBarMenuItemData>>>,
    pub hover_tips: Option<String>,
}

impl_bridge_napi_type!(StatusBarItemData, "ohos.statusbar.ItemData");

impl StatusBarItemData {
    fn validate(&self) -> Result<()> {
        if self.icons.size == 0 {
            return Err(Error::from_reason("status bar icon size must be positive"));
        }
        if self.icons.white_rgba.is_none() && self.icons.black_rgba.is_none() {
            return Err(Error::from_reason(
                "status bar requires at least one icon variant",
            ));
        }
        if let Some(tips) = self.hover_tips.as_ref() {
            let len = tips.trim().len();
            if len == 0 || len > MAX_HOVER_TIPS_LEN {
                return Err(Error::from_reason(format!(
                    "status bar hover tips must be 1..={MAX_HOVER_TIPS_LEN} chars"
                )));
            }
        }
        if let Some(groups) = self.status_bar_group_menu.as_ref() {
            for group in groups {
                if group.len() > MAX_GROUP_MENU_ITEMS {
                    return Err(Error::from_reason(format!(
                        "status bar menu group exceeds the {MAX_GROUP_MENU_ITEMS} item limit"
                    )));
                }
                for item in group {
                    item.validate()?;
                }
            }
        }
        Ok(())
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarAddRequest {
    pub item: StatusBarItemData,
}

impl_bridge_napi_type!(StatusBarAddRequest, "ohos.statusbar.AddRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarIconRequest {
    pub icon: StatusBarIconData,
}

impl_bridge_napi_type!(StatusBarIconRequest, "ohos.statusbar.IconRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarMenuRequest {
    pub groups: Vec<Vec<StatusBarMenuItemData>>,
}

impl_bridge_napi_type!(StatusBarMenuRequest, "ohos.statusbar.MenuRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarTipsRequest {
    pub tips: String,
}

impl_bridge_napi_type!(StatusBarTipsRequest, "ohos.statusbar.TipsRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StatusBarActionRequest {
    /// One of the predefined action names, e.g. `show` or `quit`.
    pub action: String,
}

impl_bridge_napi_type!(StatusBarActionRequest, "ohos.statusbar.ActionRequest");

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
                "Status bar plugin rejected the requested operation",
            ))
        }
    }
}

/// Extension trait supplied by the capability package, never by `openharmony-ability` core.
pub trait StatusBarExt {
    /// Adds a tray item. Replaces any existing item.
    fn add_to_status_bar(
        &self,
        item: StatusBarItemData,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    /// Removes the tray item.
    fn remove_from_status_bar(&self) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    /// Updates the tray icon.
    fn update_status_bar_icon(
        &self,
        icon: StatusBarIconData,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    /// Updates the tray menu groups.
    fn update_status_bar_menu(
        &self,
        groups: Vec<Vec<StatusBarMenuItemData>>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    /// Updates the hover tooltip.
    fn update_hover_tips(
        &self,
        tips: impl Into<String>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    /// Executes a predefined tray action.
    fn execute_predefined_action(
        &self,
        action: impl Into<String>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    /// Receives tray icon click types from ArkTS.
    fn icon_click_receiver() -> &'static Receiver<String>;
    /// Receives tray menu codes from ArkTS.
    fn menu_click_receiver() -> &'static Receiver<String>;
}

impl StatusBarExt for OpenHarmonyApp {
    fn add_to_status_bar(
        &self,
        item: StatusBarItemData,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        if let Err(error) = item.validate() {
            return Box::pin(async move { Err(error) });
        }
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<StatusBarBridgePlugin, StatusBarAddRequest, StatusBarAcknowledgement>(
                    "add",
                    StatusBarAddRequest { item },
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }

    fn remove_from_status_bar(&self) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<StatusBarBridgePlugin, StatusBarAddRequest, StatusBarAcknowledgement>(
                    "remove",
                    StatusBarAddRequest {
                        item: StatusBarItemData {
                            icons: StatusBarIconData {
                                white_rgba: Some(Vec::new()),
                                black_rgba: None,
                                size: 1,
                            },
                            quick_operation: QuickOperationData::default(),
                            status_bar_group_menu: None,
                            hover_tips: None,
                        },
                    },
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }

    fn update_status_bar_icon(
        &self,
        icon: StatusBarIconData,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        if icon.size == 0 {
            return Box::pin(async {
                Err(Error::from_reason("status bar icon size must be positive"))
            });
        }
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<StatusBarBridgePlugin, StatusBarIconRequest, StatusBarAcknowledgement>(
                    "update-icon",
                    StatusBarIconRequest { icon },
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }

    fn update_status_bar_menu(
        &self,
        groups: Vec<Vec<StatusBarMenuItemData>>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        for group in &groups {
            if group.len() > MAX_GROUP_MENU_ITEMS {
                return Box::pin(async {
                    Err(Error::from_reason(format!(
                        "status bar menu group exceeds the {MAX_GROUP_MENU_ITEMS} item limit"
                    )))
                });
            }
            for item in group {
                if let Err(error) = item.validate() {
                    return Box::pin(async move { Err(error) });
                }
            }
        }
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<StatusBarBridgePlugin, StatusBarMenuRequest, StatusBarAcknowledgement>(
                    "update-menu",
                    StatusBarMenuRequest { groups },
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }

    fn update_hover_tips(
        &self,
        tips: impl Into<String>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let tips = tips.into();
        let len = tips.trim().len();
        if len == 0 || len > MAX_HOVER_TIPS_LEN {
            return Box::pin(async {
                Err(Error::from_reason(format!(
                    "status bar hover tips must be 1..={MAX_HOVER_TIPS_LEN} chars"
                )))
            });
        }
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<StatusBarBridgePlugin, StatusBarTipsRequest, StatusBarAcknowledgement>(
                    "update-tips",
                    StatusBarTipsRequest { tips },
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }

    fn execute_predefined_action(
        &self,
        action: impl Into<String>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let action = action.into();
        if action.trim().is_empty() {
            return Box::pin(async {
                Err(Error::from_reason("predefined action must not be empty"))
            });
        }
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<StatusBarBridgePlugin, StatusBarActionRequest, StatusBarAcknowledgement>(
                    "predefined-action",
                    StatusBarActionRequest { action },
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }

    fn icon_click_receiver() -> &'static Receiver<String> {
        &ICON_CLICK_CHANNEL.1
    }

    fn menu_click_receiver() -> &'static Receiver<String> {
        &MENU_CLICK_CHANNEL.1
    }
}

#[cfg(test)]
mod tests {
    use super::{
        QuickOperationData, StatusBarIconData, StatusBarItemData, StatusBarMenuActionData,
        StatusBarMenuItemData,
    };
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn statusbar_uses_stable_named_napi_contracts() {
        assert_eq!(
            <StatusBarItemData as BridgeNapiType>::TYPE_NAME,
            "ohos.statusbar.ItemData"
        );
        assert_eq!(
            <StatusBarIconData as BridgeNapiType>::TYPE_NAME,
            "ohos.statusbar.IconData"
        );
    }

    #[test]
    fn statusbar_validates_item_shape() {
        let item = StatusBarItemData {
            icons: StatusBarIconData {
                white_rgba: Some(vec![0u8; 16]),
                black_rgba: None,
                size: 16,
            },
            quick_operation: QuickOperationData::default(),
            status_bar_group_menu: Some(vec![vec![StatusBarMenuItemData {
                title: "Open".to_owned(),
                menu_code: Some("open".to_owned()),
                sub_menu: None,
                menu_action: Some(StatusBarMenuActionData {
                    ability_name: "EntryAbility".to_owned(),
                    module_name: None,
                    menu_code: None,
                    notify_only: None,
                }),
                selected: None,
                icon_rgba: None,
                icon_width: None,
                icon_height: None,
            }]]),
            hover_tips: Some("hover".to_owned()),
        };
        assert!(item.validate().is_ok());

        let no_icon = StatusBarItemData {
            icons: StatusBarIconData {
                white_rgba: None,
                black_rgba: None,
                size: 16,
            },
            quick_operation: QuickOperationData::default(),
            status_bar_group_menu: None,
            hover_tips: None,
        };
        assert!(no_icon.validate().is_err());
    }
}
