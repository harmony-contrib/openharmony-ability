//! Module-local business WebView ID -> process-unique ArkWeb tag mapping.

use std::{
    collections::BTreeMap,
    sync::{LazyLock, RwLock},
};

use napi_ohos::{Error, Result};

#[derive(Default)]
struct ControllerState {
    native_tags: BTreeMap<String, String>,
}

impl ControllerState {
    fn attach(&mut self, webview_id: &str, native_tag: &str) {
        self.native_tags
            .insert(webview_id.to_owned(), native_tag.to_owned());
    }

    fn remove(&mut self, webview_id: &str, native_tag: &str) -> bool {
        if self.native_tags.get(webview_id).map(String::as_str) != Some(native_tag) {
            return false;
        }
        self.native_tags.remove(webview_id);
        true
    }

    fn native_tag(&self, webview_id: &str) -> Option<String> {
        self.native_tags.get(webview_id).cloned()
    }

    fn is_current(&self, webview_id: &str, native_tag: &str) -> bool {
        self.native_tags.get(webview_id).map(String::as_str) == Some(native_tag)
    }

    fn clear(&mut self) {
        self.native_tags.clear();
    }
}

static CONTROLLERS: LazyLock<RwLock<ControllerState>> =
    LazyLock::new(|| RwLock::new(ControllerState::default()));

pub(crate) fn on_attached(webview_id: &str, native_tag: &str) -> Result<()> {
    CONTROLLERS
        .write()
        .map_err(|_| Error::from_reason("Failed to update WebView controller tag registry"))?
        .attach(webview_id, native_tag);
    Ok(())
}

pub(crate) fn on_removed(webview_id: &str, native_tag: &str) -> Result<()> {
    CONTROLLERS
        .write()
        .map_err(|_| Error::from_reason("Failed to update WebView controller tag registry"))?
        .remove(webview_id, native_tag);
    Ok(())
}

pub fn native_tag_for(webview_id: &str) -> Result<String> {
    CONTROLLERS
        .read()
        .map_err(|_| Error::from_reason("Failed to read WebView controller tag registry"))?
        .native_tag(webview_id)
        .ok_or_else(|| {
            Error::from_reason(format!(
                "WebView '{webview_id}' has no attached ArkWeb controller"
            ))
        })
}

pub(crate) fn is_current(webview_id: &str, native_tag: &str) -> Result<bool> {
    Ok(CONTROLLERS
        .read()
        .map_err(|_| Error::from_reason("Failed to read WebView controller tag registry"))?
        .is_current(webview_id, native_tag))
}

pub(crate) fn clear_attached() -> Result<()> {
    CONTROLLERS
        .write()
        .map_err(|_| Error::from_reason("Failed to clear WebView controller tag registry"))?
        .clear();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::ControllerState;

    #[test]
    fn stale_controller_removal_cannot_clear_a_replacement_tag() {
        let mut state = ControllerState::default();
        state.attach("detail", "native-a");
        state.attach("detail", "native-b");
        assert!(!state.is_current("detail", "native-a"));
        assert!(state.is_current("detail", "native-b"));
        assert!(!state.remove("detail", "native-a"));
        assert_eq!(state.native_tag("detail").as_deref(), Some("native-b"));
        assert!(state.remove("detail", "native-b"));
        assert!(state.native_tag("detail").is_none());

        state.attach("detail", "native-c");
        state.clear();
        assert!(state.native_tag("detail").is_none());
    }
}
