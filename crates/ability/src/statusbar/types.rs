use std::cell::RefCell;
use serde::{Serialize, Deserialize};

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

#[derive(Default, Clone, Serialize, Deserialize)]
pub struct StatusBarMenuItem {
    pub title: String,
    pub menu_code: Option<String>,
    pub sub_menu: Option<Vec<StatusBarSubMenuItem>>,
    pub menu_action: Option<StatusBarMenuAction>,
    pub options: Option<StatusBarMenuItemOptions>,
}

#[derive(Default, Clone, Serialize, Deserialize)]
pub struct StatusBarSubMenuItem {
    pub sub_title: String,
    pub menu_code: Option<String>,
    pub menu_action: StatusBarMenuAction,
    pub options: Option<StatusBarMenuItemOptions>,
}

#[derive(Default, Clone, Serialize, Deserialize)]
pub struct StatusBarMenuAction {
    pub ability_name: String,
    pub module_name: Option<String>,
    pub menu_code: Option<String>,
    pub notify_only: Option<bool>,
}

#[derive(Default, Serialize, Deserialize)]
pub struct StatusBarMenuItemOptions {
    #[serde(skip)]
    pub icon: Option<StatusBarItemIcon>,
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
            selected_icon: None, // cannot clone NAPI objects
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
