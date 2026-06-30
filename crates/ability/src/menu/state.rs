use crate::menu::types::MenuItemData;
use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::RwLock;

#[napi]
pub struct MenuStateController {
    menus: Arc<RwLock<HashMap<String, Vec<MenuItemData>>>>,
}

impl Default for MenuStateController {
    fn default() -> Self {
        Self::new()
    }
}

#[napi]
impl MenuStateController {
    #[napi(constructor)]
    pub fn new() -> Self {
        Self {
            menus: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    #[napi]
    pub fn create_menu(&self, id: String, items: Vec<MenuItemData>) -> Result<()> {
        let mut guard = self
            .menus
            .write()
            .map_err(|_| Error::from_reason("lock poisoned"))?;
        guard.insert(id, items);
        Ok(())
    }

    #[napi]
    pub fn append_item(&self, menu_id: String, item: MenuItemData) -> Result<()> {
        let mut guard = self
            .menus
            .write()
            .map_err(|_| Error::from_reason("lock poisoned"))?;
        if let Some(items) = guard.get_mut(&menu_id) {
            items.push(item);
        }
        Ok(())
    }

    #[napi]
    pub fn get_menu_items(&self, menu_id: String) -> Result<Vec<MenuItemData>> {
        let guard = self
            .menus
            .read()
            .map_err(|_| Error::from_reason("lock poisoned"))?;
        Ok(guard.get(&menu_id).cloned().unwrap_or_default())
    }

    #[napi]
    pub fn destroy_menu(&self, menu_id: String) -> Result<()> {
        let mut guard = self
            .menus
            .write()
            .map_err(|_| Error::from_reason("lock poisoned"))?;
        guard.remove(&menu_id);
        Ok(())
    }
}

#[cfg(all(test, target_env = "ohos"))]
mod tests {
    use super::*;

    #[test]
    fn test_menu_state_controller_creation() {
        let controller = MenuStateController::new();
        let guard = controller.menus.read().unwrap();
        assert!(guard.is_empty());
    }

    #[test]
    fn test_menu_state_create_and_destroy() {
        let controller = MenuStateController::new();

        let mut guard = controller.menus.write().unwrap();
        guard.insert("test".to_string(), vec![]);
        assert!(guard.contains_key("test"));
        guard.remove("test");
        assert!(!guard.contains_key("test"));
    }
}
