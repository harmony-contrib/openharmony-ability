use crate::menu::types::MenuItemData;
use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::RwLock;

#[napi]
pub struct MenuPopup {
    menus: Arc<RwLock<HashMap<String, Vec<MenuItemData>>>>,
}

impl Default for MenuPopup {
    fn default() -> Self {
        Self::new()
    }
}

#[napi]
impl MenuPopup {
    #[napi(constructor)]
    pub fn new() -> Self {
        Self {
            menus: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    #[napi]
    pub fn set_menu_items(&self, menu_id: String, items: Vec<MenuItemData>) -> Result<()> {
        let mut guard = self
            .menus
            .write()
            .map_err(|_| Error::from_reason("lock poisoned"))?;
        guard.insert(menu_id, items);
        Ok(())
    }

    #[napi]
    pub fn show(&self, menu_id: String, x: f64, y: f64) -> Result<()> {
        let guard = self
            .menus
            .read()
            .map_err(|_| Error::from_reason("lock poisoned"))?;
        let items = guard.get(&menu_id).cloned().unwrap_or_default();

        let _json = serde_json::to_string(&PopupData {
            menu_id,
            items,
            x,
            y,
        })
        .map_err(|e| Error::from_reason(e.to_string()))?;

        Ok(())
    }

    #[napi]
    pub fn hide(&self) -> Result<()> {
        Ok(())
    }
}

#[derive(serde::Serialize)]
struct PopupData {
    menu_id: String,
    items: Vec<MenuItemData>,
    x: f64,
    y: f64,
}

#[cfg(all(test, target_env = "ohos"))]
mod tests {
    use super::*;

    #[test]
    fn test_menu_popup_creation() {
        let popup = MenuPopup::new();
        let guard = popup.menus.read().unwrap();
        assert!(guard.is_empty());
    }
}
