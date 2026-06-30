use crate::menu::types::MenuItemData;
use napi_derive_ohos::napi;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PredefinedType {
    Copy,
    Cut,
    Paste,
    SelectAll,
    Undo,
    Redo,
    Minimize,
    Maximize,
    Recover,
    Restore,
    DestroyWindow,
    Quit,
    Hide,
    HideOthers,
    ShowAll,
    About,
    Separator,
}

impl PredefinedType {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Copy => "copy",
            Self::Cut => "cut",
            Self::Paste => "paste",
            Self::SelectAll => "selectAll",
            Self::Undo => "undo",
            Self::Redo => "redo",
            Self::Minimize => "minimize",
            Self::Maximize => "maximize",
            Self::Recover => "recover",
            Self::Restore => "restore",
            Self::DestroyWindow => "destroyWindow",
            Self::Quit => "quit",
            Self::Hide => "hide",
            Self::HideOthers => "hideOthers",
            Self::ShowAll => "showAll",
            Self::About => "about",
            Self::Separator => "separator",
        }
    }

    pub fn display_text(&self) -> &'static str {
        match self {
            Self::Copy => "Copy",
            Self::Cut => "Cut",
            Self::Paste => "Paste",
            Self::SelectAll => "Select All",
            Self::Undo => "Undo",
            Self::Redo => "Redo",
            Self::Minimize => "Minimize",
            Self::Maximize => "Maximize",
            Self::Recover => "Restore",
            Self::Restore => "Restore",
            Self::DestroyWindow => "Close Window",
            Self::Quit => "Quit",
            Self::Hide => "Hide",
            Self::HideOthers => "Hide Others",
            Self::ShowAll => "Show All",
            Self::About => "About",
            Self::Separator => "",
        }
    }

    pub fn is_supported_on_ohos(&self) -> bool {
        !matches!(self, Self::HideOthers | Self::ShowAll)
}
}

#[napi]
pub struct PredefinedMenuItem {
    predefined_type: PredefinedType,
    id: String,
    text: Option<String>,
    accelerator: Option<String>,
}

#[napi]
impl PredefinedMenuItem {
    #[napi(factory)]
    pub fn copy(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Copy,
            id: id.unwrap_or_else(|| "predefined_copy".to_string()),
            text,
            accelerator: Some("Ctrl+C".to_string()),
        }
    }

    #[napi(factory)]
    pub fn cut(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Cut,
            id: id.unwrap_or_else(|| "predefined_cut".to_string()),
            text,
            accelerator: Some("Ctrl+X".to_string()),
        }
    }

    #[napi(factory)]
    pub fn paste(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Paste,
            id: id.unwrap_or_else(|| "predefined_paste".to_string()),
            text,
            accelerator: Some("Ctrl+V".to_string()),
        }
    }

    #[napi(factory)]
    pub fn select_all(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::SelectAll,
            id: id.unwrap_or_else(|| "predefined_selectAll".to_string()),
            text,
            accelerator: Some("Ctrl+A".to_string()),
        }
    }

    #[napi(factory)]
    pub fn undo(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Undo,
            id: id.unwrap_or_else(|| "predefined_undo".to_string()),
            text,
            accelerator: Some("Ctrl+Z".to_string()),
        }
    }

    #[napi(factory)]
    pub fn redo(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Redo,
            id: id.unwrap_or_else(|| "predefined_redo".to_string()),
            text,
            accelerator: Some("Ctrl+Y".to_string()),
        }
    }

    #[napi(factory)]
    pub fn minimize(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Minimize,
            id: id.unwrap_or_else(|| "predefined_minimize".to_string()),
            text,
            accelerator: Some("Ctrl+M".to_string()),
        }
    }

    #[napi(factory)]
    pub fn maximize(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Maximize,
            id: id.unwrap_or_else(|| "predefined_maximize".to_string()),
            text,
            accelerator: None,
        }
    }

    #[napi(factory)]
    pub fn close_window(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::DestroyWindow,
            id: id.unwrap_or_else(|| "predefined_close".to_string()),
            text,
            accelerator: Some("Ctrl+W".to_string()),
        }
    }

    #[napi(factory)]
    pub fn quit(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Quit,
            id: id.unwrap_or_else(|| "predefined_quit".to_string()),
            text,
            accelerator: Some("Ctrl+Q".to_string()),
        }
    }

    #[napi(factory)]
    pub fn separator(id: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Separator,
            id: id.unwrap_or_else(|| format!("separator_{}", uuid::Uuid::new_v4())),
            text: None,
            accelerator: None,
        }
    }

    #[napi(factory)]
    pub fn recover(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Recover,
            id: id.unwrap_or_else(|| "predefined_recover".to_string()),
            text,
            accelerator: None,
        }
    }

    #[napi(factory)]
    pub fn restore(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Restore,
            id: id.unwrap_or_else(|| "predefined_restore".to_string()),
            text,
            accelerator: None,
        }
    }

    #[napi(factory)]
    pub fn hide(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::Hide,
            id: id.unwrap_or_else(|| "predefined_hide".to_string()),
            text,
            accelerator: None,
        }
    }

    #[napi(factory)]
    pub fn hide_others(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::HideOthers,
            id: id.unwrap_or_else(|| "predefined_hideOthers".to_string()),
            text,
            accelerator: None,
        }
    }

    #[napi(factory)]
    pub fn show_all(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::ShowAll,
            id: id.unwrap_or_else(|| "predefined_showAll".to_string()),
            text,
            accelerator: None,
        }
    }

    #[napi(factory)]
    pub fn about(id: Option<String>, text: Option<String>) -> Self {
        Self {
            predefined_type: PredefinedType::About,
            id: id.unwrap_or_else(|| "predefined_about".to_string()),
            text,
            accelerator: None,
        }
    }

    #[napi]
    pub fn id(&self) -> String {
        self.id.clone()
    }

    #[napi]
    pub fn text(&self) -> Option<String> {
        self.text
            .clone()
            .or_else(|| Some(self.predefined_type.display_text().to_string()))
    }

    pub fn to_data(&self) -> MenuItemData {
        MenuItemData {
            id: self.id.clone(),
            item_type: "predefined".to_string(),
            text: self
                .text
                .clone()
                .or_else(|| Some(self.predefined_type.display_text().to_string())),
            enabled: Some(self.predefined_type.is_supported_on_ohos()),
            accelerator: self.accelerator.clone(),
            predefined_type: Some(self.predefined_type.as_str().to_string()),
            checked: None,
            icon: None,
            native_icon: None,
            submenu_items: None,
            about_metadata: None,
        }
    }
}

#[cfg(all(test, target_env = "ohos"))]
mod tests {
    use super::*;

    #[test]
    fn test_predefined_copy_factory() {
        let item = PredefinedMenuItem::copy(None, None);
        assert_eq!(item.predefined_type, PredefinedType::Copy);
        assert_eq!(item.accelerator, Some("Ctrl+C".to_string()));
        assert!(item.predefined_type.is_supported_on_ohos());
    }

    #[test]
    fn test_predefined_minimize_factory() {
        let item = PredefinedMenuItem::minimize(None, None);
        assert_eq!(item.predefined_type, PredefinedType::Minimize);
        assert!(item.predefined_type.is_supported_on_ohos());
    }

    #[test]
    fn test_predefined_separator_factory() {
        let item = PredefinedMenuItem::separator(None);
        assert_eq!(item.predefined_type, PredefinedType::Separator);
    }

    #[test]
    fn test_unsupported_items() {
        assert!(!PredefinedType::HideOthers.is_supported_on_ohos());
        assert!(!PredefinedType::ShowAll.is_supported_on_ohos());
    }

    #[test]
    fn test_display_text() {
        assert_eq!(PredefinedType::Copy.display_text(), "Copy");
        assert_eq!(PredefinedType::Minimize.display_text(), "Minimize");
        assert_eq!(PredefinedType::Recover.display_text(), "Restore");
    }

    #[test]
    fn test_recover_factory() {
        let item = PredefinedMenuItem::recover(None, None);
        assert_eq!(item.predefined_type, PredefinedType::Recover);
        assert!(item.id.starts_with("predefined_recover"));
    }

    #[test]
    fn test_restore_factory() {
        let item = PredefinedMenuItem::restore(None, None);
        assert_eq!(item.predefined_type, PredefinedType::Restore);
        assert!(item.id.starts_with("predefined_restore"));
    }

    #[test]
    fn test_hide_factory() {
        let item = PredefinedMenuItem::hide(None, None);
        assert_eq!(item.predefined_type, PredefinedType::Hide);
        assert!(item.id.starts_with("predefined_hide"));
    }

    #[test]
    fn test_hide_others_factory() {
        let item = PredefinedMenuItem::hide_others(None, None);
        assert_eq!(item.predefined_type, PredefinedType::HideOthers);
        assert!(!item.predefined_type.is_supported_on_ohos());
    }

    #[test]
    fn test_show_all_factory() {
        let item = PredefinedMenuItem::show_all(None, None);
        assert_eq!(item.predefined_type, PredefinedType::ShowAll);
        assert!(!item.predefined_type.is_supported_on_ohos());
    }

    #[test]
    fn test_about_factory() {
        let item = PredefinedMenuItem::about(None, None);
        assert_eq!(item.predefined_type, PredefinedType::About);
        assert!(item.id.starts_with("predefined_about"));
    }
}
