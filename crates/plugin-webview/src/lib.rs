//! WebView plugin facade.
//!
//! The plugin is intentionally named-N-API-value/controller-ID based. Rust never keeps an ArkTS
//! `WebviewController` or `ObjectRef`; the ArkTS HAR mounts its own `FrameNode` into the session
//! root, or under a caller-provided `ohos.node` container handle.

use std::collections::BTreeMap;

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Either, Error, Result};
use ohos_web_binding::Web;
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
    PluginLifecycleEvent,
};

mod callbacks;
mod controller;
mod js_proxy;
mod protocol;

pub use callbacks::WebviewCallbacksBuilder;
pub use js_proxy::WebviewJavascriptProxyBuilder;
pub use protocol::{
    bind_custom_protocol, bind_custom_protocol_async, WebviewProtocol, WebviewProtocolOptions,
    WebviewProtocolRequest, WebviewProtocolResponder, WebviewProtocolResponse,
};

const BEFORE_ENGINE_INIT_EVENT: &str = "before-engine-init";
const SEAL_ENGINE_SCHEMES_EVENT: &str = "seal-engine-schemes";
const ENGINE_INITIALIZED_EVENT: &str = "engine-initialized";
const CONTROLLER_ATTACHED_EVENT: &str = "controller-attached";

pub struct WebviewBridgePlugin;

impl BridgePlugin for WebviewBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.webview";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::UiContext];

    fn required_contexts_for_main_thread_event(
        &self,
        event_name: &str,
    ) -> &'static [BridgeContextRequirement] {
        match event_name {
            SEAL_ENGINE_SCHEMES_EVENT | BEFORE_ENGINE_INIT_EVENT | ENGINE_INITIALIZED_EVENT => {
                &[BridgeContextRequirement::Ability]
            }
            _ => Self::REQUIRED_CONTEXTS,
        }
    }

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        match event.name() {
            SEAL_ENGINE_SCHEMES_EVENT => {
                let lifecycle = event.decode::<WebviewEngineLifecycleEvent>()?;
                expect_engine_phase(&lifecycle, SEAL_ENGINE_SCHEMES_EVENT)?;
                WebviewProtocol::seal_before_engine_init()?;
                event.respond(engine_lifecycle_response()?)
            }
            BEFORE_ENGINE_INIT_EVENT => {
                let lifecycle = event.decode::<WebviewEngineLifecycleEvent>()?;
                expect_engine_phase(&lifecycle, BEFORE_ENGINE_INIT_EVENT)?;
                WebviewProtocol::validate_process_schemes(&engine_scheme_pairs(&lifecycle))?;
                WebviewProtocol::flush_before_engine_init()?;
                event.respond(engine_lifecycle_response()?)
            }
            ENGINE_INITIALIZED_EVENT => {
                let lifecycle = event.decode::<WebviewEngineLifecycleEvent>()?;
                expect_engine_phase(&lifecycle, ENGINE_INITIALIZED_EVENT)?;
                WebviewProtocol::mark_engine_initialized(&engine_scheme_pairs(&lifecycle))?;
                event.respond(engine_lifecycle_response()?)
            }
            CONTROLLER_ATTACHED_EVENT => {
                let controller = event.decode::<WebviewControllerEvent>()?;
                let (webview_id, native_tag) = controller_identity(controller)?;
                controller::on_attached(&webview_id, &native_tag)?;
                // Both registries own Rust closures only. Flush them on the scoped main-thread
                // event after ArkWeb has created its BrowserContext and before ArkTS begins the
                // first navigation.
                protocol::on_controller_attached(&webview_id, &native_tag)?;
                js_proxy::on_controller_attached(&webview_id, &native_tag)?;
                event.respond(WebviewEventAcknowledgement { accepted: true })
            }
            "controller-removed" => {
                let controller = event.decode::<WebviewControllerEvent>()?;
                let (webview_id, native_tag) = controller_identity(controller)?;
                protocol::on_controller_removed(&webview_id, &native_tag)?;
                js_proxy::on_controller_removed(&webview_id, &native_tag)?;
                controller::on_removed(&webview_id, &native_tag)?;
                event.respond(WebviewEventAcknowledgement { accepted: true })
            }
            "navigation-request" => {
                let request = event.decode::<WebviewNavigationRequest>()?;
                event.respond(callbacks::navigation_decision(request)?)
            }
            "download-start" => {
                let request = event.decode::<WebviewDownloadStartRequest>()?;
                event.respond(callbacks::download_start_decision(request)?)
            }
            "download-end" => {
                let notification = event.decode::<WebviewDownloadEndEvent>()?;
                callbacks::dispatch_download_end(notification)?;
                event.respond(WebviewEventAcknowledgement { accepted: true })
            }
            "title-change" => {
                let notification = event.decode::<WebviewTitleChangeEvent>()?;
                callbacks::dispatch_title_change(notification)?;
                event.respond(WebviewEventAcknowledgement { accepted: true })
            }
            _ => Err(Error::from_reason(format!(
                "Unsupported ohos.webview main-thread event '{}'",
                event.name()
            ))),
        }
    }

    fn on_lifecycle(&self, event: &PluginLifecycleEvent) -> Result<()> {
        if matches!(
            event,
            PluginLifecycleEvent::UiContextDestroyed | PluginLifecycleEvent::AbilityDestroyed
        ) {
            clear_attached_webview_state()?;
        }
        Ok(())
    }
}

fn clear_attached_webview_state() -> Result<()> {
    let mut first_error = None;
    for result in [
        controller::clear_attached(),
        protocol::clear_attached(),
        js_proxy::clear_attached(),
    ] {
        if let Err(error) = result {
            if first_error.is_none() {
                first_error = Some(error);
            }
        }
    }
    first_error.map_or(Ok(()), Err)
}

fn expect_engine_phase(event: &WebviewEngineLifecycleEvent, expected: &str) -> Result<()> {
    if event.phase == expected {
        Ok(())
    } else {
        Err(Error::from_reason(format!(
            "Invalid WebView engine lifecycle phase '{}', expected '{expected}'",
            event.phase
        )))
    }
}

fn engine_scheme_pairs(event: &WebviewEngineLifecycleEvent) -> Vec<(String, u32)> {
    event
        .schemes
        .iter()
        .map(|declaration| (declaration.scheme.clone(), declaration.options))
        .collect()
}

fn engine_lifecycle_response() -> Result<WebviewEngineLifecycleResponse> {
    Ok(WebviewEngineLifecycleResponse {
        accepted: true,
        schemes: WebviewProtocol::declared_schemes()?
            .into_iter()
            .map(|(scheme, options)| WebviewSchemeDeclaration { scheme, options })
            .collect(),
    })
}

fn controller_identity(event: WebviewControllerEvent) -> Result<(String, String)> {
    if event.id.trim().is_empty() {
        return Err(Error::from_reason(
            "WebView controller event id must not be empty",
        ));
    }
    if event.native_tag.trim().is_empty() {
        return Err(Error::from_reason(
            "WebView controller event nativeTag must not be empty",
        ));
    }
    Ok((event.id, event.native_tag))
}

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct WebviewStyle {
    pub x: Option<Either<f64, String>>,
    pub y: Option<Either<f64, String>>,
    /// Optional width override. Defaults to the full container size; numbers are vp, strings are
    /// ArkUI length expressions (for example "30%").
    pub width: Option<Either<f64, String>>,
    /// Optional height override. Defaults to the full container size; numbers are vp, strings are
    /// ArkUI length expressions. Combined with `y` (for example y = "70%", height = "30%") a
    /// WebView can be rendered in a corner or along one edge instead of full-screen.
    pub height: Option<Either<f64, String>>,
    pub visible: Option<bool>,
    pub background_color: Option<String>,
}

/// Engine lifecycle signal delivered directly from the ArkTS WebView host.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewEngineLifecycleEvent {
    pub phase: String,
    /// Process-global scheme set sealed before ArkWeb initialization. A facade activated after
    /// the engine started may join only when every local declaration already exists in this set
    /// with identical options.
    pub schemes: Vec<WebviewSchemeDeclaration>,
}

impl_bridge_napi_type!(
    WebviewEngineLifecycleEvent,
    "ohos.webview.EngineLifecycleEvent"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewSchemeDeclaration {
    pub scheme: String,
    pub options: u32,
}

impl_bridge_napi_type!(WebviewSchemeDeclaration, "ohos.webview.SchemeDeclaration");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewEngineLifecycleResponse {
    pub accepted: bool,
    pub schemes: Vec<WebviewSchemeDeclaration>,
}

impl_bridge_napi_type!(
    WebviewEngineLifecycleResponse,
    "ohos.webview.EngineLifecycleResponse"
);

/// Controller lifecycle signal delivered directly from the ArkTS WebView host.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewControllerEvent {
    pub id: String,
    /// Process-unique ArkWeb controller tag generated by the ArkTS host. The public WebView ID
    /// remains local to one plugin facade and is never used as a process-global platform key.
    pub native_tag: String,
}

impl_bridge_napi_type!(WebviewControllerEvent, "ohos.webview.ControllerEvent");

/// Event subscriptions derived from Rust callback declarations before a WebView is created.
///
/// This is transport state, not an ArkTS callback reference. The ArkTS host uses it only to bind
/// the corresponding ArkWeb delegate/event hooks for the new controller.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct WebviewCallbackOptions {
    pub navigation_intercept: bool,
    pub download_start: bool,
    pub download_end: bool,
    pub title_change: bool,
}

/// A document-start script and the URL rules for pages where ArkWeb may inject it.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewInitializationScript {
    pub script: String,
    pub script_rules: Vec<String>,
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewCreateRequest {
    pub id: String,
    /// Optional opaque container handle issued by the built-in `ohos.node` plugin. When provided,
    /// the ArkTS host appends the WebView FrameNode under that container instead of the current
    /// plugin Host's DefaultXComponent root.
    pub parent_handle: Option<u32>,
    pub url: Option<String>,
    pub html: Option<String>,
    pub style: WebviewStyle,
    pub javascript_enabled: Option<bool>,
    pub devtools: Option<bool>,
    pub user_agent: Option<String>,
    pub autoplay: Option<bool>,
    pub initialization_scripts: Option<Vec<WebviewInitializationScript>>,
    pub headers: Option<BTreeMap<String, String>>,
    /// Restores the legacy creation-time transparent-background policy. An explicit style
    /// background color takes precedence.
    pub transparent: Option<bool>,
    #[doc(hidden)]
    pub event_options: WebviewCallbackOptions,
}

impl_bridge_napi_type!(WebviewCreateRequest, "ohos.webview.CreateRequest");

impl WebviewCreateRequest {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            parent_handle: None,
            url: None,
            html: None,
            style: WebviewStyle::default(),
            javascript_enabled: None,
            devtools: None,
            user_agent: None,
            autoplay: None,
            initialization_scripts: None,
            headers: None,
            transparent: None,
            event_options: WebviewCallbackOptions::default(),
        }
    }

    /// Mounts the WebView FrameNode under the given `ohos.node` container handle instead of the
    /// component root, so an RS-layer node tree can adopt WebViews as children.
    pub fn parent_node(mut self, handle: u32) -> Self {
        self.parent_handle = Some(handle);
        self
    }

    pub fn url(mut self, url: impl Into<String>) -> Self {
        self.url = Some(url.into());
        self
    }

    pub fn html(mut self, html: impl Into<String>) -> Self {
        self.html = Some(html.into());
        self
    }

    pub fn style(mut self, style: WebviewStyle) -> Self {
        self.style = style;
        self
    }

    /// Uses a transparent background when no explicit style background color was supplied.
    pub fn transparent(mut self, transparent: bool) -> Self {
        self.transparent = Some(transparent);
        self
    }

    pub fn initialization_scripts(
        mut self,
        scripts: impl IntoIterator<Item = WebviewInitializationScript>,
    ) -> Self {
        self.initialization_scripts = Some(scripts.into_iter().collect());
        self
    }

    fn validate(&self) -> Result<()> {
        if self.id.trim().is_empty() {
            return Err(Error::from_reason("WebView id must not be empty"));
        }
        if self.url.is_some() == self.html.is_some() {
            return Err(Error::from_reason(
                "WebView requires exactly one source: url or html",
            ));
        }
        Ok(())
    }
}

/// Request delivered synchronously when ArkWeb asks whether a navigation should be intercepted.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewNavigationRequest {
    pub id: String,
    /// Process-unique controller generation used to reject callbacks from a replaced WebView.
    pub native_tag: String,
    pub url: String,
}

impl_bridge_napi_type!(WebviewNavigationRequest, "ohos.webview.NavigationRequest");

/// Synchronous navigation decision. A true value retains ArkWeb's existing intercept semantics.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewNavigationResponse {
    pub intercept: bool,
}

impl_bridge_napi_type!(WebviewNavigationResponse, "ohos.webview.NavigationResponse");

/// Request delivered synchronously before ArkWeb starts a download.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewDownloadStartRequest {
    pub id: String,
    /// Process-unique controller generation used to reject callbacks from a replaced WebView.
    pub native_tag: String,
    pub url: String,
    pub temp_path: Option<String>,
}

impl_bridge_napi_type!(
    WebviewDownloadStartRequest,
    "ohos.webview.DownloadStartRequest"
);

/// Immediate download admission and optional replacement destination.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewDownloadStartResponse {
    pub allow: bool,
    pub temp_path: Option<String>,
}

impl_bridge_napi_type!(
    WebviewDownloadStartResponse,
    "ohos.webview.DownloadStartResponse"
);

impl WebviewDownloadStartResponse {
    pub fn allow(temp_path: Option<String>) -> Self {
        Self {
            allow: true,
            temp_path,
        }
    }

    pub fn cancel() -> Self {
        Self {
            allow: false,
            temp_path: None,
        }
    }
}

/// Completion notification delivered directly through a named N-API callback.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewDownloadEndEvent {
    pub id: String,
    /// Process-unique controller generation used to reject callbacks from a replaced WebView.
    pub native_tag: String,
    pub url: String,
    pub temp_path: Option<String>,
    pub success: bool,
}

/// Title-change notification delivered directly through a named N-API callback.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewTitleChangeEvent {
    pub id: String,
    /// Process-unique controller generation used to reject callbacks from a replaced WebView.
    pub native_tag: String,
    pub title: String,
}

impl_bridge_napi_type!(WebviewDownloadEndEvent, "ohos.webview.DownloadEndEvent");
impl_bridge_napi_type!(WebviewTitleChangeEvent, "ohos.webview.TitleChangeEvent");

/// Response used by one-way named N-API notifications sent directly from ArkTS.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewEventAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    WebviewEventAcknowledgement,
    "ohos.webview.EventAcknowledgement"
);

#[derive(Clone)]
pub struct WebviewClient {
    bridge: BridgeRuntime,
}

impl WebviewClient {
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }

    pub async fn create(&self, mut request: WebviewCreateRequest) -> Result<WebviewHandle> {
        request.validate()?;
        // Callback declarations live solely in Rust. Snapshot their event subscriptions into the
        // named create request so ArkTS can bind ArkWeb hooks without retaining Rust closures.
        request.event_options = callbacks::options_for(&request.id)?;
        let request_id = request.id.clone();
        let response: WebviewCreateResponse = self.call("create", request).await?;
        if response.id != request_id {
            return Err(Error::from_reason(
                "WebView plugin returned a mismatched controller ID",
            ));
        }
        Ok(WebviewHandle {
            client: self.clone(),
            id: response.id,
        })
    }

    /// Reopens a controller-ID facade for a WebView already created by this plugin facade.
    pub fn handle(&self, id: impl Into<String>) -> WebviewHandle {
        WebviewHandle {
            client: self.clone(),
            id: id.into(),
        }
    }

    /// Declares a custom-scheme handler by facade-local WebView ID before the ArkTS node is created.
    ///
    /// The Rust closure is queued and attached from the controller-attached main-thread event,
    /// before the initial URL is loaded. This is the preferred route when the first URL uses that
    /// scheme.
    pub fn custom_protocol<S, F>(
        &self,
        webview_id: impl Into<String>,
        scheme: S,
        callback: F,
    ) -> Result<()>
    where
        S: AsRef<str>,
        F: Fn(&str, WebviewProtocolRequest, bool) -> Option<WebviewProtocolResponse>
            + Send
            + Sync
            + 'static,
    {
        bind_custom_protocol(webview_id, scheme, callback)
    }

    /// Async custom-scheme handler variant. The responder may be moved to a Rust worker.
    pub fn custom_protocol_async<S, F>(
        &self,
        webview_id: impl Into<String>,
        scheme: S,
        callback: F,
    ) -> Result<()>
    where
        S: AsRef<str>,
        F: Fn(&str, WebviewProtocolRequest, bool, WebviewProtocolResponder) + Send + Sync + 'static,
    {
        bind_custom_protocol_async(webview_id, scheme, callback)
    }

    async fn call<Request, Response>(&self, action: &str, request: Request) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.bridge
            .call_async::<WebviewBridgePlugin, Request, Response>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await
    }
}

pub trait WebviewExt {
    fn webview(&self) -> Result<WebviewClient>;
}

impl WebviewExt for OpenHarmonyApp {
    fn webview(&self) -> Result<WebviewClient> {
        WebviewClient::new(self)
    }
}

#[derive(Clone)]
pub struct WebviewHandle {
    client: WebviewClient,
    id: String,
}

impl WebviewHandle {
    pub fn id(&self) -> &str {
        &self.id
    }

    fn controller_request(&self) -> WebviewControllerRequest {
        WebviewControllerRequest {
            id: self.id.clone(),
            visible: None,
            color: None,
            url: None,
            html: None,
            headers: None,
            zoom: None,
        }
    }

    async fn acknowledge(&self, action: &str, request: WebviewControllerRequest) -> Result<()> {
        self.client
            .call::<_, WebviewAcknowledgement>(action, request)
            .await?
            .ensure()
    }

    async fn string_value(
        &self,
        action: &str,
        request: WebviewControllerRequest,
    ) -> Result<Option<String>> {
        Ok(self
            .client
            .call::<_, WebviewStringResponse>(action, request)
            .await?
            .value)
    }

    /// Declares a handler for this controller ID. For a first custom-scheme load, prefer
    /// [`WebviewClient::custom_protocol`] before calling [`WebviewClient::create`].
    pub fn custom_protocol<S, F>(&self, scheme: S, callback: F) -> Result<()>
    where
        S: AsRef<str>,
        F: Fn(&str, WebviewProtocolRequest, bool) -> Option<WebviewProtocolResponse>
            + Send
            + Sync
            + 'static,
    {
        self.client.custom_protocol(&self.id, scheme, callback)
    }

    pub fn custom_protocol_async<S, F>(&self, scheme: S, callback: F) -> Result<()>
    where
        S: AsRef<str>,
        F: Fn(&str, WebviewProtocolRequest, bool, WebviewProtocolResponder) + Send + Sync + 'static,
    {
        self.client
            .custom_protocol_async(&self.id, scheme, callback)
    }

    /// Registers a native ArkWeb controller-attached callback for the currently attached
    /// controller. The public ID is resolved to the process-unique native tag first.
    pub fn on_controller_attach<F>(&self, callback: F) -> Result<()>
    where
        F: FnMut() + 'static,
    {
        Web::new(controller::native_tag_for(&self.id)?)
            .on_controller_attach(callback)
            .map_err(|error| {
                Error::from_reason(format!(
                    "Failed to register WebView controller callback: {error}"
                ))
            })
    }

    pub fn on_page_begin<F>(&self, callback: F) -> Result<()>
    where
        F: FnMut() + 'static,
    {
        Web::new(controller::native_tag_for(&self.id)?)
            .on_page_begin(callback)
            .map_err(|error| {
                Error::from_reason(format!(
                    "Failed to register WebView page-begin callback: {error}"
                ))
            })
    }

    pub fn on_page_end<F>(&self, callback: F) -> Result<()>
    where
        F: FnMut() + 'static,
    {
        Web::new(controller::native_tag_for(&self.id)?)
            .on_page_end(callback)
            .map_err(|error| {
                Error::from_reason(format!(
                    "Failed to register WebView page-end callback: {error}"
                ))
            })
    }

    pub fn on_destroy<F>(&self, callback: F) -> Result<()>
    where
        F: FnMut() + 'static,
    {
        Web::new(controller::native_tag_for(&self.id)?)
            .on_destroy(callback)
            .map_err(|error| {
                Error::from_reason(format!(
                    "Failed to register WebView destroy callback: {error}"
                ))
            })
    }

    pub async fn set_visible(&self, visible: bool) -> Result<()> {
        self.acknowledge(
            "set-visible",
            WebviewControllerRequest {
                visible: Some(visible),
                ..self.controller_request()
            },
        )
        .await
    }

    pub async fn set_background_color(&self, color: impl Into<String>) -> Result<()> {
        self.acknowledge(
            "set-background-color",
            WebviewControllerRequest {
                color: Some(color.into()),
                ..self.controller_request()
            },
        )
        .await
    }

    /// Repositions and resizes the WebView surface (per-window bounds).
    pub async fn set_bounds(&self, x: f64, y: f64, width: f64, height: f64) -> Result<()> {
        let request = WebviewBoundsRequest {
            id: self.id.clone(),
            x,
            y,
            width,
            height,
        };
        request.validate()?;
        self.client
            .call::<_, WebviewAcknowledgement>("set-bounds", request)
            .await?
            .ensure()
    }

    /// Sets a single cookie for the given URL via `WebCookieManager.configCookieSync`.
    pub async fn set_cookie(&self, url: impl Into<String>, value: impl Into<String>) -> Result<()> {
        let request = WebviewCookieRequest {
            id: self.id.clone(),
            url: url.into(),
            value: value.into(),
        };
        request.validate()?;
        self.client
            .call::<_, WebviewAcknowledgement>("set-cookie", request)
            .await?
            .ensure()
    }

    /// Captures the current page as RGBA pixels.
    pub async fn snapshot(&self) -> Result<Option<(Vec<u8>, u32, u32)>> {
        let response = self
            .client
            .call::<_, WebviewSnapshotResponse>(
                "snapshot",
                WebviewSnapshotRequest {
                    id: self.id.clone(),
                },
            )
            .await?;
        Ok(response
            .rgba
            .map(|rgba| (rgba, response.width, response.height)))
    }

    /// Toggles Web debugging at runtime (`setWebDebuggingAccess`).
    pub async fn set_web_debugging_access(&self, enabled: bool) -> Result<()> {
        self.client
            .call::<_, WebviewAcknowledgement>(
                "set-debugging-access",
                WebviewBoolRequest {
                    id: self.id.clone(),
                    enabled: Some(enabled),
                },
            )
            .await?
            .ensure()
    }

    /// Reads the current Web debugging access flag.
    pub async fn is_web_debugging_access(&self) -> Result<bool> {
        let response = self
            .client
            .call::<_, WebviewBoolResponse>(
                "is-debugging-access",
                WebviewBoolRequest {
                    id: self.id.clone(),
                    enabled: None,
                },
            )
            .await?;
        Ok(response.value)
    }

    /// Generates a PDF of the current page into `path`. Must be called after the page has
    /// fully loaded (`on_page_end`).
    pub async fn create_pdf(
        &self,
        path: impl Into<String>,
        config: Option<PdfConfig>,
    ) -> Result<()> {
        let request = WebviewPdfRequest {
            id: self.id.clone(),
            path: path.into(),
            config,
        };
        request.validate()?;
        self.client
            .call::<_, WebviewAcknowledgement>("create-pdf", request)
            .await?
            .ensure()
    }

    pub async fn remove(&self) -> Result<()> {
        self.acknowledge("remove", self.controller_request()).await
    }

    /// Returns the URL currently owned by this WebView controller.
    pub async fn url(&self) -> Result<String> {
        self.string_value("get-url", self.controller_request())
            .await?
            .ok_or_else(|| Error::from_reason("WebView controller returned no current URL"))
    }

    pub async fn load_url(&self, url: impl Into<String>) -> Result<()> {
        self.acknowledge(
            "load-url",
            WebviewControllerRequest {
                url: Some(url.into()),
                ..self.controller_request()
            },
        )
        .await
    }

    pub async fn load_url_with_headers(
        &self,
        url: impl Into<String>,
        headers: BTreeMap<String, String>,
    ) -> Result<()> {
        self.acknowledge(
            "load-url",
            WebviewControllerRequest {
                url: Some(url.into()),
                headers: Some(headers),
                ..self.controller_request()
            },
        )
        .await
    }

    pub async fn load_html(&self, html: impl Into<String>) -> Result<()> {
        self.acknowledge(
            "load-html",
            WebviewControllerRequest {
                html: Some(html.into()),
                ..self.controller_request()
            },
        )
        .await
    }

    pub async fn set_zoom(&self, zoom: f64) -> Result<()> {
        if !zoom.is_finite() {
            return Err(Error::from_reason("WebView zoom must be finite"));
        }
        self.acknowledge(
            "set-zoom",
            WebviewControllerRequest {
                zoom: Some(zoom),
                ..self.controller_request()
            },
        )
        .await
    }

    pub async fn reload(&self) -> Result<()> {
        self.acknowledge("reload", self.controller_request()).await
    }

    pub async fn focus(&self) -> Result<()> {
        self.acknowledge("focus", self.controller_request()).await
    }

    pub async fn cookies_with_url(&self, url: impl Into<String>) -> Result<String> {
        self.string_value(
            "cookies-with-url",
            WebviewControllerRequest {
                url: Some(url.into()),
                ..self.controller_request()
            },
        )
        .await?
        .ok_or_else(|| Error::from_reason("WebView cookie manager returned no cookie string"))
    }

    pub async fn clear_all_browsing_data(&self) -> Result<()> {
        self.acknowledge("clear-all-browsing-data", self.controller_request())
            .await
    }

    /// Named replacement for the old `dispose` controller operation.
    pub async fn dispose(&self) -> Result<()> {
        self.remove().await
    }

    /// Evaluates JavaScript in the currently loaded page and returns its string result.
    ///
    /// This is asynchronous because ArkWeb runs `runJavaScript` and its completion callback on
    /// the UI thread. `None` is the platform representation of a script with no return value.
    pub async fn evaluate_script(&self, script: impl Into<String>) -> Result<Option<String>> {
        let response = self
            .client
            .call::<_, WebviewScriptResponse>(
                "evaluate-script",
                WebviewScriptRequest {
                    id: self.id.clone(),
                    script: script.into(),
                },
            )
            .await?;
        Ok(response.result)
    }

    /// Callback-shaped convenience for callers migrating from the former controller API.
    pub async fn evaluate_script_with_callback<F>(
        &self,
        script: impl Into<String>,
        callback: F,
    ) -> Result<()>
    where
        F: FnOnce(Option<String>) + Send,
    {
        callback(self.evaluate_script(script).await?);
        Ok(())
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewCreateResponse {
    pub id: String,
}

impl_bridge_napi_type!(WebviewCreateResponse, "ohos.webview.CreateResponse");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewScriptRequest {
    pub id: String,
    pub script: String,
}

impl_bridge_napi_type!(WebviewScriptRequest, "ohos.webview.ScriptRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewScriptResponse {
    pub result: Option<String>,
}

impl_bridge_napi_type!(WebviewScriptResponse, "ohos.webview.ScriptResponse");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewControllerRequest {
    pub id: String,
    pub visible: Option<bool>,
    pub color: Option<String>,
    pub url: Option<String>,
    pub html: Option<String>,
    pub headers: Option<BTreeMap<String, String>>,
    pub zoom: Option<f64>,
}

impl_bridge_napi_type!(WebviewControllerRequest, "ohos.webview.ControllerRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewStringResponse {
    pub value: Option<String>,
}

impl_bridge_napi_type!(WebviewStringResponse, "ohos.webview.StringResponse");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewBoundsRequest {
    pub id: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl_bridge_napi_type!(WebviewBoundsRequest, "ohos.webview.BoundsRequest");

impl WebviewBoundsRequest {
    fn validate(&self) -> Result<()> {
        if self.id.trim().is_empty() {
            return Err(Error::from_reason("WebView id must not be empty"));
        }
        if !self.width.is_finite()
            || !self.height.is_finite()
            || self.width <= 0.0
            || self.height <= 0.0
        {
            return Err(Error::from_reason(
                "WebView bounds width and height must be positive finite numbers",
            ));
        }
        Ok(())
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewCookieRequest {
    pub id: String,
    pub url: String,
    /// Set-Cookie format value, e.g. `name=value; Domain=...; Path=...`.
    pub value: String,
}

impl_bridge_napi_type!(WebviewCookieRequest, "ohos.webview.CookieRequest");

impl WebviewCookieRequest {
    fn validate(&self) -> Result<()> {
        if self.id.trim().is_empty() {
            return Err(Error::from_reason("WebView id must not be empty"));
        }
        if self.url.trim().is_empty() {
            return Err(Error::from_reason("cookie url must not be empty"));
        }
        if self.value.trim().is_empty() {
            return Err(Error::from_reason("cookie value must not be empty"));
        }
        Ok(())
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewSnapshotRequest {
    pub id: String,
}

impl_bridge_napi_type!(WebviewSnapshotRequest, "ohos.webview.SnapshotRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewSnapshotResponse {
    pub rgba: Option<Vec<u8>>,
    pub width: u32,
    pub height: u32,
}

impl_bridge_napi_type!(WebviewSnapshotResponse, "ohos.webview.SnapshotResponse");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewBoolRequest {
    pub id: String,
    pub enabled: Option<bool>,
}

impl_bridge_napi_type!(WebviewBoolRequest, "ohos.webview.BoolRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewBoolResponse {
    pub value: bool,
}

impl_bridge_napi_type!(WebviewBoolResponse, "ohos.webview.BoolResponse");

/// PDF export options. Field names match ArkTS `PdfConfiguration`.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct PdfConfig {
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub margin_top: Option<f64>,
    pub margin_bottom: Option<f64>,
    pub margin_left: Option<f64>,
    pub margin_right: Option<f64>,
    pub scale: Option<f64>,
    pub should_print_background: Option<bool>,
}

impl_bridge_napi_type!(PdfConfig, "ohos.webview.PdfConfig");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewPdfRequest {
    pub id: String,
    pub path: String,
    pub config: Option<PdfConfig>,
}

impl_bridge_napi_type!(WebviewPdfRequest, "ohos.webview.PdfRequest");

impl WebviewPdfRequest {
    fn validate(&self) -> Result<()> {
        if self.id.trim().is_empty() {
            return Err(Error::from_reason("WebView id must not be empty"));
        }
        if self.path.trim().is_empty() {
            return Err(Error::from_reason("pdf path must not be empty"));
        }
        if let Some(config) = &self.config {
            validate_positive_pdf_value("width", config.width)?;
            validate_positive_pdf_value("height", config.height)?;
            validate_non_negative_pdf_value("margin_top", config.margin_top)?;
            validate_non_negative_pdf_value("margin_bottom", config.margin_bottom)?;
            validate_non_negative_pdf_value("margin_left", config.margin_left)?;
            validate_non_negative_pdf_value("margin_right", config.margin_right)?;
            validate_positive_pdf_value("scale", config.scale)?;
        }
        Ok(())
    }
}

fn validate_positive_pdf_value(name: &str, value: Option<f64>) -> Result<()> {
    if value.is_some_and(|value| !value.is_finite() || value <= 0.0) {
        return Err(Error::from_reason(format!(
            "pdf {name} must be a finite positive number"
        )));
    }
    Ok(())
}

fn validate_non_negative_pdf_value(name: &str, value: Option<f64>) -> Result<()> {
    if value.is_some_and(|value| !value.is_finite() || value < 0.0) {
        return Err(Error::from_reason(format!(
            "pdf {name} must be a finite non-negative number"
        )));
    }
    Ok(())
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(WebviewAcknowledgement, "ohos.webview.Acknowledgement");

impl WebviewAcknowledgement {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "WebView plugin rejected the requested operation",
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn create_request_retains_optional_value_semantics() {
        let request = WebviewCreateRequest::new("webview")
            .parent_node(7)
            .transparent(true)
            .url("https://example.test");
        assert_eq!(request.id, "webview");
        assert_eq!(request.parent_handle, Some(7));
        assert_eq!(request.url.as_deref(), Some("https://example.test"));
        assert!(request.html.is_none());
        assert!(request.headers.is_none());
        assert_eq!(request.transparent, Some(true));
    }

    #[test]
    fn create_request_defaults_to_session_root_mount() {
        let request = WebviewCreateRequest::new("webview").html("<p>hi</p>");
        assert!(request.parent_handle.is_none());
    }

    #[test]
    fn webview_id_remains_an_opaque_business_identifier() {
        let request = WebviewCreateRequest::new("window 2 / detail#1").html("<p>hi</p>");
        assert!(request.validate().is_ok());
    }

    #[test]
    fn controller_event_separates_business_id_from_process_native_tag() {
        let identity = controller_identity(WebviewControllerEvent {
            id: "detail".to_owned(),
            native_tag: "ohos.webview.bridge-1.demo-native.7".to_owned(),
        })
        .unwrap();
        assert_eq!(identity.0, "detail");
        assert_eq!(identity.1, "ohos.webview.bridge-1.demo-native.7");
        assert!(controller_identity(WebviewControllerEvent {
            id: "detail".to_owned(),
            native_tag: " ".to_owned(),
        })
        .is_err());
    }

    #[test]
    fn webview_actions_have_named_napi_contracts() {
        assert_eq!(
            <WebviewCreateRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.CreateRequest"
        );
        assert_eq!(
            <WebviewCreateResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.CreateResponse"
        );
        assert_eq!(
            <WebviewControllerRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.ControllerRequest"
        );
        assert_eq!(
            <WebviewAcknowledgement as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.Acknowledgement"
        );
        assert_eq!(
            <WebviewScriptRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.ScriptRequest"
        );
        assert_eq!(
            <WebviewScriptResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.ScriptResponse"
        );
        assert_eq!(
            <WebviewStringResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.StringResponse"
        );
        assert_eq!(
            <WebviewEngineLifecycleEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.EngineLifecycleEvent"
        );
        assert_eq!(
            <WebviewSchemeDeclaration as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.SchemeDeclaration"
        );
        assert_eq!(
            <WebviewEngineLifecycleResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.EngineLifecycleResponse"
        );
        assert_eq!(
            <WebviewControllerEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.ControllerEvent"
        );
        assert_eq!(
            <WebviewNavigationRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.NavigationRequest"
        );
        assert_eq!(
            <WebviewNavigationResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.NavigationResponse"
        );
        assert_eq!(
            <WebviewDownloadStartRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.DownloadStartRequest"
        );
        assert_eq!(
            <WebviewDownloadStartResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.DownloadStartResponse"
        );
        assert_eq!(
            <WebviewDownloadEndEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.DownloadEndEvent"
        );
        assert_eq!(
            <WebviewTitleChangeEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.TitleChangeEvent"
        );
        assert_eq!(
            <WebviewEventAcknowledgement as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.EventAcknowledgement"
        );
    }

    #[test]
    fn pdf_request_rejects_invalid_geometry() {
        let request = WebviewPdfRequest {
            id: "webview".to_owned(),
            path: "/data/storage/el2/base/files/page.pdf".to_owned(),
            config: Some(PdfConfig {
                width: Some(0.0),
                ..PdfConfig::default()
            }),
        };
        assert!(request.validate().is_err());

        let request = WebviewPdfRequest {
            id: "webview".to_owned(),
            path: "/data/storage/el2/base/files/page.pdf".to_owned(),
            config: Some(PdfConfig {
                margin_top: Some(-1.0),
                ..PdfConfig::default()
            }),
        };
        assert!(request.validate().is_err());
    }

    #[test]
    fn engine_events_are_ability_scoped_but_controller_events_require_ui() {
        let plugin = WebviewBridgePlugin;
        assert_eq!(
            plugin.required_contexts_for_main_thread_event(SEAL_ENGINE_SCHEMES_EVENT),
            &[BridgeContextRequirement::Ability]
        );
        assert_eq!(
            plugin.required_contexts_for_main_thread_event(BEFORE_ENGINE_INIT_EVENT),
            &[BridgeContextRequirement::Ability]
        );
        assert_eq!(
            plugin.required_contexts_for_main_thread_event(ENGINE_INITIALIZED_EVENT),
            &[BridgeContextRequirement::Ability]
        );
        assert_eq!(
            plugin.required_contexts_for_main_thread_event(CONTROLLER_ATTACHED_EVENT),
            &[BridgeContextRequirement::UiContext]
        );
    }
}
