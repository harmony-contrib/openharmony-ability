//! Web-page JavaScript → Rust proxy support owned by the WebView plugin.
//!
//! ArkWeb requires a JavaScript proxy to be registered after its controller has attached. The
//! public builder therefore queues declarations by module-local WebView ID and
//! `WebviewBridgePlugin` flushes
//! them when the ArkTS Web component reports `controller-attached`. This keeps the page callback
//! in native ArkWeb while avoiding an ArkTS object or N-API function reference on a Rust worker.

use std::{
    collections::BTreeMap,
    sync::{Arc, LazyLock, Mutex},
};

use napi_ohos::{Error, Result};
use ohos_web_binding::WebProxyBuilder as ArkWebProxyBuilder;

type ProxyCallback = Arc<Mutex<Box<dyn FnMut(String, Vec<String>) + Send + 'static>>>;

#[derive(Clone)]
struct ProxyMethod {
    name: String,
    callback: ProxyCallback,
}

#[derive(Clone)]
struct ProxyDeclaration {
    webview_id: String,
    object_name: String,
    methods: Vec<ProxyMethod>,
}

#[derive(Default)]
struct ProxyState {
    /// Business WebView ID -> process-unique ArkWeb controller tag.
    attached_webviews: BTreeMap<String, String>,
    declarations: BTreeMap<String, Vec<ProxyDeclaration>>,
}

static PROXY_STATE: LazyLock<Mutex<ProxyState>> =
    LazyLock::new(|| Mutex::new(ProxyState::default()));

/// Builder for a persistent JavaScript object exposed to a WebView page.
///
/// The registered object is available as `window.<object_name>` and each declared method receives
/// the module-local business WebView ID plus stringified page arguments. Calling [`Self::build`]
/// before `create` is the preferred path: the declaration is installed exactly when the
/// process-unique ArkWeb controller attaches, before the initial document is loaded.
pub struct WebviewJavascriptProxyBuilder {
    webview_id: String,
    object_name: String,
    methods: Vec<ProxyMethod>,
}

impl WebviewJavascriptProxyBuilder {
    pub fn new(webview_id: impl Into<String>, object_name: impl Into<String>) -> Self {
        Self {
            webview_id: webview_id.into(),
            object_name: object_name.into(),
            methods: Vec::new(),
        }
    }

    /// Adds a `window.<object_name>.<method_name>(...args)` callback.
    pub fn add_method<F>(mut self, method_name: impl Into<String>, callback: F) -> Self
    where
        F: FnMut(String, Vec<String>) + Send + 'static,
    {
        self.methods.push(ProxyMethod {
            name: method_name.into(),
            callback: Arc::new(Mutex::new(Box::new(callback))),
        });
        self
    }

    /// Queues the declaration until the WebView controller attaches, or installs it immediately
    /// and reloads the page when the controller is already attached. Declarations survive a
    /// remove/create cycle for the same WebView ID.
    pub fn build(self) -> Result<()> {
        let declaration = self.into_declaration()?;
        let declaration_to_install = {
            let mut state = PROXY_STATE
                .lock()
                .map_err(|_| Error::from_reason("Failed to lock WebView JavaScript proxy state"))?;
            let native_tag = state
                .attached_webviews
                .get(&declaration.webview_id)
                .cloned();
            state
                .declarations
                .entry(declaration.webview_id.clone())
                .or_default()
                .push(declaration.clone());
            native_tag.map(|native_tag| (declaration, native_tag))
        };
        if let Some((declaration, native_tag)) = declaration_to_install {
            install(declaration, &native_tag, true)?;
        }
        Ok(())
    }

    fn into_declaration(self) -> Result<ProxyDeclaration> {
        if self.webview_id.trim().is_empty() {
            return Err(Error::from_reason(
                "WebView JavaScript proxy id must not be empty",
            ));
        }
        if self.object_name.trim().is_empty() {
            return Err(Error::from_reason(
                "WebView JavaScript proxy object name must not be empty",
            ));
        }
        if self.methods.is_empty()
            || self
                .methods
                .iter()
                .any(|method| method.name.trim().is_empty())
        {
            return Err(Error::from_reason(
                "WebView JavaScript proxy must declare one or more non-empty method names",
            ));
        }
        Ok(ProxyDeclaration {
            webview_id: self.webview_id,
            object_name: self.object_name,
            methods: self.methods,
        })
    }
}

/// Flushes queued page-to-Rust proxies once ArkTS has attached the native controller.
pub(crate) fn on_controller_attached(webview_id: &str, native_tag: &str) -> Result<()> {
    let declarations = {
        let mut state = PROXY_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView JavaScript proxy state"))?;
        let previous_tag = state
            .attached_webviews
            .insert(webview_id.to_owned(), native_tag.to_owned());
        if previous_tag.as_deref() == Some(native_tag) {
            return Ok(());
        }
        state
            .declarations
            .get(webview_id)
            .cloned()
            .unwrap_or_default()
    };

    for declaration in declarations {
        install(declaration, native_tag, false)?;
    }
    Ok(())
}

/// Marks a controller detached. Declarations remain queued for a future controller using the
/// same WebView ID, while ArkWeb owns proxies that were already installed.
pub(crate) fn on_controller_removed(webview_id: &str, native_tag: &str) -> Result<()> {
    let mut state = PROXY_STATE
        .lock()
        .map_err(|_| Error::from_reason("Failed to lock WebView JavaScript proxy state"))?;
    if state.attached_webviews.get(webview_id).map(String::as_str) != Some(native_tag) {
        return Ok(());
    }
    state.attached_webviews.remove(webview_id);
    Ok(())
}

/// Clears controller-generation state at component/session teardown. Proxy declarations remain
/// available for a later controller created with the same module-local business ID.
pub(crate) fn clear_attached() -> Result<()> {
    PROXY_STATE
        .lock()
        .map_err(|_| Error::from_reason("Failed to clear WebView JavaScript proxy state"))?
        .attached_webviews
        .clear();
    Ok(())
}

fn install(
    declaration: ProxyDeclaration,
    native_tag: &str,
    refresh_after_install: bool,
) -> Result<()> {
    let webview_id = declaration.webview_id;
    let mut builder = ArkWebProxyBuilder::new(native_tag.to_owned(), declaration.object_name);
    for method in declaration.methods {
        let callback = Arc::clone(&method.callback);
        let callback_webview_id = webview_id.clone();
        builder = builder.add_method(method.name, move |_native_tag, arguments| {
            if let Ok(mut callback) = callback.lock() {
                callback(callback_webview_id.clone(), arguments);
            }
        });
    }

    let proxy = builder.build().map_err(|error| {
        Error::from_reason(format!(
            "Failed to register WebView JavaScript proxy: {error}"
        ))
    })?;
    if refresh_after_install {
        proxy.refresh().map_err(|error| {
            Error::from_reason(format!(
                "Failed to refresh WebView after JavaScript proxy registration: {error}"
            ))
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::WebviewJavascriptProxyBuilder;

    #[test]
    fn proxy_builder_rejects_invalid_declarations_before_touching_arkweb() {
        assert!(WebviewJavascriptProxyBuilder::new("", "native")
            .add_method("echo", |_tag, _arguments| {})
            .build()
            .is_err());
        assert!(WebviewJavascriptProxyBuilder::new("web", "")
            .add_method("echo", |_tag, _arguments| {})
            .build()
            .is_err());
        assert!(WebviewJavascriptProxyBuilder::new("web", "native")
            .build()
            .is_err());
    }
}
