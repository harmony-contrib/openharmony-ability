//! Module-local business WebView ID -> process-unique ArkWeb tag mapping.

use std::{
    collections::BTreeMap,
    sync::{LazyLock, RwLock},
};

use crate::controller_key::ControllerKey;
use napi_ohos::{Error, Result};
use std::sync::Arc;

#[derive(Default)]
struct ControllerState {
    native_tags: BTreeMap<ControllerKey, String>,
}

impl ControllerState {
    fn attach(&mut self, webview_id: &ControllerKey, native_tag: &str) {
        self.native_tags
            .insert(webview_id.to_owned(), native_tag.to_owned());
    }

    fn remove(&mut self, webview_id: &ControllerKey, native_tag: &str) -> bool {
        if self.native_tags.get(webview_id).map(String::as_str) != Some(native_tag) {
            return false;
        }
        self.native_tags.remove(webview_id);
        true
    }

    fn native_tag(&self, webview_id: &ControllerKey) -> Option<String> {
        self.native_tags.get(webview_id).cloned()
    }

    fn is_current(&self, webview_id: &ControllerKey, native_tag: &str) -> bool {
        self.native_tags.get(webview_id).map(String::as_str) == Some(native_tag)
    }

    fn clear(&mut self, owner: Option<&Arc<()>>) {
        self.native_tags.retain(|key, _| !key.belongs_to(owner));
    }
}

static CONTROLLERS: LazyLock<RwLock<ControllerState>> =
    LazyLock::new(|| RwLock::new(ControllerState::default()));

pub(crate) fn on_attached(webview_id: &ControllerKey, native_tag: &str) -> Result<()> {
    CONTROLLERS
        .write()
        .map_err(|_| Error::from_reason("Failed to update WebView controller tag registry"))?
        .attach(webview_id, native_tag);
    Ok(())
}

pub(crate) fn on_removed(webview_id: &ControllerKey, native_tag: &str) -> Result<()> {
    CONTROLLERS
        .write()
        .map_err(|_| Error::from_reason("Failed to update WebView controller tag registry"))?
        .remove(webview_id, native_tag);
    Ok(())
}

pub fn native_tag_for(webview_id: &str) -> Result<String> {
    native_tag_for_key(&ControllerKey::from(webview_id))
}

pub(crate) fn native_tag_for_key(webview_id: &ControllerKey) -> Result<String> {
    CONTROLLERS
        .read()
        .map_err(|_| Error::from_reason("Failed to read WebView controller tag registry"))?
        .native_tag(webview_id)
        .ok_or_else(|| {
            Error::from_reason(format!(
                "WebView '{}' has no attached ArkWeb controller",
                webview_id.id()
            ))
        })
}

pub(crate) fn is_current(webview_id: &ControllerKey, native_tag: &str) -> Result<bool> {
    Ok(CONTROLLERS
        .read()
        .map_err(|_| Error::from_reason("Failed to read WebView controller tag registry"))?
        .is_current(webview_id, native_tag))
}

pub(crate) fn clear_attached(owner: Option<&Arc<()>>) -> Result<()> {
    CONTROLLERS
        .write()
        .map_err(|_| Error::from_reason("Failed to clear WebView controller tag registry"))?
        .clear(owner);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::ControllerState;

    #[test]
    fn stale_controller_removal_cannot_clear_a_replacement_tag() {
        let mut state = ControllerState::default();
        state.attach(&"detail".into(), "native-a");
        state.attach(&"detail".into(), "native-b");
        assert!(!state.is_current(&"detail".into(), "native-a"));
        assert!(state.is_current(&"detail".into(), "native-b"));
        assert!(!state.remove(&"detail".into(), "native-a"));
        assert_eq!(
            state.native_tag(&"detail".into()).as_deref(),
            Some("native-b")
        );
        assert!(state.remove(&"detail".into(), "native-b"));
        assert!(state.native_tag(&"detail".into()).is_none());

        state.attach(&"detail".into(), "native-c");
        state.clear(None);
        assert!(state.native_tag(&"detail".into()).is_none());
    }
}
