use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use serde::{Deserialize, Serialize};

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

#[napi]
pub struct Menu {
    id: String,
    items: Vec<MenuItemData>,
}

#[napi]
impl Menu {
    #[napi(constructor)]
    pub fn new(id: Option<String>) -> Self {
        Self {
            id: id.unwrap_or_else(|| format!("menu_{}", uuid::Uuid::new_v4())),
            items: vec![],
        }
    }

    #[napi]
    pub fn id(&self) -> String {
        self.id.clone()
    }

    #[napi]
    pub fn append(&mut self, item: MenuItemData) -> Result<()> {
        self.items.push(item);
        Ok(())
    }

    #[napi]
    pub fn items(&self) -> Vec<MenuItemData> {
        self.items.clone()
    }

    pub fn to_data(&self) -> MenuItemData {
        MenuItemData {
            id: self.id.clone(),
            item_type: "menu".to_string(),
            text: None,
            enabled: Some(true),
            accelerator: None,
            predefined_type: None,
            checked: None,
            icon: None,
            native_icon: None,
            submenu_items: Some(self.items.clone()),
            about_metadata: None,
        }
    }
}

#[napi]
pub struct MenuItem {
    id: String,
    text: String,
    enabled: bool,
    accelerator: Option<String>,
}

#[napi]
impl MenuItem {
    #[napi(constructor)]
    pub fn new(
        id: Option<String>,
        text: String,
        enabled: Option<bool>,
        accelerator: Option<String>,
    ) -> Self {
        Self {
            id: id.unwrap_or_else(|| format!("item_{}", uuid::Uuid::new_v4())),
            text,
            enabled: enabled.unwrap_or(true),
            accelerator,
        }
    }

    #[napi]
    pub fn id(&self) -> String {
        self.id.clone()
    }

    #[napi]
    pub fn text(&self) -> String {
        self.text.clone()
    }

    #[napi]
    pub fn set_text(&mut self, text: String) {
        self.text = text;
    }

    #[napi]
    pub fn enabled(&self) -> bool {
        self.enabled
    }

    #[napi]
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    pub fn to_data(&self) -> MenuItemData {
        MenuItemData {
            id: self.id.clone(),
            item_type: "item".to_string(),
            text: Some(self.text.clone()),
            enabled: Some(self.enabled),
            accelerator: self.accelerator.clone(),
            predefined_type: None,
            checked: None,
            icon: None,
            native_icon: None,
            submenu_items: None,
            about_metadata: None,
        }
    }
}

#[napi]
pub struct Submenu {
    id: String,
    text: String,
    items: Vec<MenuItemData>,
}

#[napi]
impl Submenu {
    #[napi(constructor)]
    pub fn new(id: Option<String>, text: String) -> Self {
        Self {
            id: id.unwrap_or_else(|| format!("submenu_{}", uuid::Uuid::new_v4())),
            text,
            items: vec![],
        }
    }

    #[napi]
    pub fn id(&self) -> String {
        self.id.clone()
    }

    #[napi]
    pub fn text(&self) -> String {
        self.text.clone()
    }

    #[napi]
    pub fn set_text(&mut self, text: String) {
        self.text = text;
    }

    #[napi]
    pub fn append(&mut self, item: MenuItemData) -> Result<()> {
        self.items.push(item);
        Ok(())
    }

    #[napi]
    pub fn items(&self) -> Vec<MenuItemData> {
        self.items.clone()
    }

    pub fn to_data(&self) -> MenuItemData {
        MenuItemData {
            id: self.id.clone(),
            item_type: "submenu".to_string(),
            text: Some(self.text.clone()),
            enabled: Some(true),
            accelerator: None,
            predefined_type: None,
            checked: None,
            icon: None,
            native_icon: None,
            submenu_items: Some(self.items.clone()),
            about_metadata: None,
        }
    }
}

#[cfg(all(test, target_env = "ohos"))]
mod tests {
    use super::*;

    #[test]
    fn test_menu_item_data_creation() {
        let data = MenuItemData {
            id: "item1".to_string(),
            item_type: "item".to_string(),
            text: Some("File".to_string()),
            enabled: Some(true),
            accelerator: Some("Ctrl+F".to_string()),
            predefined_type: None,
            checked: None,
            icon: None,
            native_icon: None,
            submenu_items: None,
            about_metadata: None,
        };
        assert_eq!(data.id, "item1");
        assert_eq!(data.item_type, "item");
    }

    #[test]
    fn test_submenu_nested_items() {
        let submenu_data = MenuItemData {
            id: "submenu_1".to_string(),
            item_type: "submenu".to_string(),
            text: Some("File".to_string()),
            enabled: Some(true),
            accelerator: None,
            predefined_type: None,
            checked: None,
            icon: None,
            native_icon: None,
            submenu_items: Some(vec![MenuItemData {
                id: "item_1".to_string(),
                item_type: "item".to_string(),
                text: Some("Open".to_string()),
                enabled: Some(true),
                accelerator: None,
                predefined_type: None,
                checked: None,
                icon: None,
            native_icon: None,
                submenu_items: None,
                about_metadata: None,
            }]),
            about_metadata: None,
        };
        assert!(submenu_data.submenu_items.is_some());
        assert_eq!(submenu_data.submenu_items.unwrap().len(), 1);
    }

    #[test]
    fn test_menu_creation() {
        let menu = Menu::new(None);
        assert!(menu.id.starts_with("menu_"));
    }

    #[test]
    fn test_menu_item_creation() {
        let item = MenuItem::new(None, "Test".to_string(), None, Some("Ctrl+T".to_string()));
        assert!(item.id.starts_with("item_"));
        assert_eq!(item.text, "Test");
        assert_eq!(item.accelerator, Some("Ctrl+T".to_string()));
    }

    #[test]
    fn test_menu_item_data_serde_roundtrip() {
        let data = MenuItemData {
            id: "roundtrip1".to_string(),
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
        assert_eq!(parsed.enabled, data.enabled);
        assert_eq!(parsed.accelerator, data.accelerator);
        assert!(parsed.predefined_type.is_none());
        assert!(parsed.checked.is_none());
        assert!(parsed.icon.is_none());
        assert!(parsed.submenu_items.is_none());
        assert!(parsed.about_metadata.is_none());
    }

    #[test]
    fn test_menu_item_data_serde_skip_none() {
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
    fn test_submenu_data_with_predefined_child() {
        let predefined = MenuItemData {
            id: "quit".to_string(),
            item_type: "predefined".to_string(),
            text: Some("Quit".to_string()),
            enabled: Some(true),
            accelerator: Some("Ctrl+Q".to_string()),
            predefined_type: Some("quit".to_string()),
            checked: None,
            icon: None,
            native_icon: None,
            submenu_items: None,
            about_metadata: None,
        };
        let submenu = MenuItemData {
            id: "file".to_string(),
            item_type: "submenu".to_string(),
            text: Some("File".to_string()),
            enabled: Some(true),
            accelerator: None,
            predefined_type: None,
            checked: None,
            icon: None,
            native_icon: None,
            submenu_items: Some(vec![predefined]),
            about_metadata: None,
        };
        let json = serde_json::to_string(&submenu).unwrap();
        let parsed: MenuItemData = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.item_type, "submenu");
        let children = parsed.submenu_items.unwrap();
        assert_eq!(children.len(), 1);
        assert_eq!(children[0].predefined_type, Some("quit".to_string()));
        assert_eq!(children[0].accelerator, Some("Ctrl+Q".to_string()));
    }

    #[test]
    fn test_about_metadata_data_serde_roundtrip() {
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
        assert_eq!(parsed.comments, meta.comments);
        assert_eq!(parsed.copyright, meta.copyright);
        assert_eq!(parsed.license, meta.license);
        assert_eq!(parsed.website, meta.website);
    }

    #[test]
    fn test_about_metadata_skip_none_fields() {
        let meta = AboutMetadataData {
            name: Some("App".to_string()),
            version: None,
            short_version: None,
            authors: None,
            comments: None,
            copyright: None,
            license: None,
            website: None,
        };
        let json = serde_json::to_string(&meta).unwrap();
        assert!(json.contains("\"name\""));
        assert!(!json.contains("\"version\""));
        assert!(!json.contains("\"shortVersion\""));
        assert!(!json.contains("\"authors\""));
    }
}
