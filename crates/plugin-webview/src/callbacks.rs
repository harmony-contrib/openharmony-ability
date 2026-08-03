//! Rust-owned WebView callback declarations.
//!
//! The registry stores only Rust closures keyed by WebView tag. ArkTS receives a boolean
//! subscription snapshot as part of create, then invokes every ArkWeb callback through a scoped
//! named N-API event. No ArkTS Function, ObjectRef, or JSON event payload is kept by Rust.

use std::{
    collections::BTreeMap,
    sync::{Arc, LazyLock, RwLock},
};

use napi_ohos::{Error, Result};

use super::{
    WebviewCallbackOptions, WebviewDownloadEndEvent, WebviewDownloadStartRequest,
    WebviewDownloadStartResponse, WebviewNavigationRequest, WebviewNavigationResponse,
    WebviewTitleChangeEvent,
};

type NavigationCallback = Arc<dyn Fn(WebviewNavigationRequest) -> bool + Send + Sync + 'static>;
type DownloadStartCallback = Arc<
    dyn Fn(WebviewDownloadStartRequest) -> WebviewDownloadStartResponse + Send + Sync + 'static,
>;
type DownloadEndCallback = Arc<dyn Fn(WebviewDownloadEndEvent) + Send + Sync + 'static>;
type TitleChangeCallback = Arc<dyn Fn(WebviewTitleChangeEvent) + Send + Sync + 'static>;

#[derive(Default, Clone)]
struct WebviewCallbacks {
    navigation: Option<NavigationCallback>,
    download_start: Option<DownloadStartCallback>,
    download_end: Option<DownloadEndCallback>,
    title_change: Option<TitleChangeCallback>,
}

impl WebviewCallbacks {
    fn options(&self) -> WebviewCallbackOptions {
        WebviewCallbackOptions {
            navigation_intercept: self.navigation.is_some(),
            download_start: self.download_start.is_some(),
            download_end: self.download_end.is_some(),
            title_change: self.title_change.is_some(),
        }
    }

    fn is_empty(&self) -> bool {
        self.navigation.is_none()
            && self.download_start.is_none()
            && self.download_end.is_none()
            && self.title_change.is_none()
    }
}

static CALLBACKS: LazyLock<RwLock<BTreeMap<String, WebviewCallbacks>>> =
    LazyLock::new(|| RwLock::new(BTreeMap::new()));

/// Builder for Rust-owned WebView lifecycle and platform callbacks.
///
/// Build this before WebviewClient::create. Calling build for the same tag replaces the previous
/// declaration and callback declarations remain valid across a remove and create cycle.
#[derive(Default)]
pub struct WebviewCallbacksBuilder {
    webview_id: String,
    callbacks: WebviewCallbacks,
}

impl WebviewCallbacksBuilder {
    pub fn new(webview_id: impl Into<String>) -> Self {
        Self {
            webview_id: webview_id.into(),
            callbacks: WebviewCallbacks::default(),
        }
    }

    /// Decides whether ArkWeb should intercept a navigation. The callback runs synchronously on
    /// the active N-API main-thread callback and must return promptly.
    pub fn on_navigation_request<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewNavigationRequest) -> bool + Send + Sync + 'static,
    {
        self.callbacks.navigation = Some(Arc::new(callback));
        self
    }

    /// Admits, cancels, or redirects a download before ArkWeb starts it. The callback runs
    /// synchronously on the active N-API main-thread callback and must return promptly.
    pub fn on_download_start<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewDownloadStartRequest) -> WebviewDownloadStartResponse + Send + Sync + 'static,
    {
        self.callbacks.download_start = Some(Arc::new(callback));
        self
    }

    /// Receives successful and failed download completion notifications on the active N-API
    /// callback. It has no platform decision response, but should still return promptly.
    pub fn on_download_end<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewDownloadEndEvent) + Send + Sync + 'static,
    {
        self.callbacks.download_end = Some(Arc::new(callback));
        self
    }

    /// Receives page title updates on the active N-API callback and should return promptly.
    pub fn on_title_change<F>(mut self, callback: F) -> Self
    where
        F: Fn(WebviewTitleChangeEvent) + Send + Sync + 'static,
    {
        self.callbacks.title_change = Some(Arc::new(callback));
        self
    }

    pub fn build(self) -> Result<()> {
        if self.webview_id.trim().is_empty() {
            return Err(Error::from_reason("WebView callback id must not be empty"));
        }
        if self.callbacks.is_empty() {
            return Err(Error::from_reason(
                "WebView callbacks must declare at least one callback",
            ));
        }
        CALLBACKS
            .write()
            .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
            .insert(self.webview_id, self.callbacks);
        Ok(())
    }
}

pub(crate) fn options_for(webview_id: &str) -> Result<WebviewCallbackOptions> {
    let callbacks = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?;
    Ok(callbacks
        .get(webview_id)
        .map(WebviewCallbacks::options)
        .unwrap_or_default())
}

pub(crate) fn navigation_decision(
    request: WebviewNavigationRequest,
) -> Result<WebviewNavigationResponse> {
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&request.id)
        .and_then(|callbacks| callbacks.navigation.as_ref())
        .cloned();
    Ok(WebviewNavigationResponse {
        intercept: callback.map(|callback| callback(request)).unwrap_or(false),
    })
}

pub(crate) fn download_start_decision(
    request: WebviewDownloadStartRequest,
) -> Result<WebviewDownloadStartResponse> {
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&request.id)
        .and_then(|callbacks| callbacks.download_start.as_ref())
        .cloned();
    Ok(callback
        .map(|callback| callback(request))
        .unwrap_or_else(WebviewDownloadStartResponse::cancel))
}

pub(crate) fn dispatch_download_end(event: WebviewDownloadEndEvent) -> Result<()> {
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&event.id)
        .and_then(|callbacks| callbacks.download_end.as_ref())
        .cloned();
    if let Some(callback) = callback {
        callback(event);
    }
    Ok(())
}

pub(crate) fn dispatch_title_change(event: WebviewTitleChangeEvent) -> Result<()> {
    let callback = CALLBACKS
        .read()
        .map_err(|_| Error::from_reason("Failed to lock WebView callback registry"))?
        .get(&event.id)
        .and_then(|callbacks| callbacks.title_change.as_ref())
        .cloned();
    if let Some(callback) = callback {
        callback(event);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::WebviewCallbacksBuilder;

    #[test]
    fn callback_builder_rejects_an_empty_declaration() {
        assert!(WebviewCallbacksBuilder::new("webview").build().is_err());
    }
}
