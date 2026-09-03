//! WebView plugin facade.
//!
//! The plugin is intentionally named-N-API-value/controller-ID based. Rust never keeps an ArkTS
//! `WebviewController` or `ObjectRef`; the ArkTS HAR mounts its own `FrameNode` into the session
//! root, or under a caller-provided `ohos.node` container handle.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use crossbeam_channel::{unbounded, Receiver, Sender};
use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Error, Result};
// Re-export Either so downstream crates (e.g. the webview consumer) can construct
// `WebviewStyle` fields without directly depending on `napi-ohos`.
pub use napi_ohos::Either;
use ohos_web_binding::Web;
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
    PluginLifecycleEvent,
};

mod callbacks;
pub mod controller;
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
            "drag-enter" => {
                let drag_event = event.decode::<WebviewDragEvent>()?;
                callbacks::dispatch_drag_enter(drag_event)?;
                event.respond(WebviewEventAcknowledgement { accepted: true })
            }
            "drag-over" => {
                let drag_event = event.decode::<WebviewDragEvent>()?;
                callbacks::dispatch_drag_over(drag_event)?;
                event.respond(WebviewEventAcknowledgement { accepted: true })
            }
            "drag-drop" => {
                let drop_event = event.decode::<WebviewDropEvent>()?;
                callbacks::dispatch_drag_drop(drop_event)?;
                event.respond(WebviewEventAcknowledgement { accepted: true })
            }
            "drag-leave" => {
                let drag_event = event.decode::<WebviewDragEvent>()?;
                callbacks::dispatch_drag_leave(drag_event)?;
                event.respond(WebviewEventAcknowledgement { accepted: true })
            }
            "new-window-request" => {
                let request = event.decode::<WebviewNewWindowRequest>()?;
                event.respond(callbacks::new_window_decision(request)?)
            }
            "page-begin" => {
                let page_event = event.decode::<WebviewPageEvent>()?;
                callbacks::dispatch_page_begin(page_event)?;
                event.respond(WebviewEventAcknowledgement { accepted: true })
            }
            "page-end" => {
                let page_event = event.decode::<WebviewPageEvent>()?;
                callbacks::dispatch_page_end(page_event)?;
                event.respond(WebviewEventAcknowledgement { accepted: true })
            }
            "download-start" => {
                let request = event.decode::<WebviewDownloadStartRequest>()?;
                event.respond(callbacks::download_start_decision(request)?)
            }
            "https-intercept" => {
                let request = event.decode::<WebviewHttpsInterceptRequest>()?;
                log::info!(
                    "[bridge https-intercept] received: id={} native_tag={} url={}",
                    request.id, request.native_tag, request.url
                );
                let result = callbacks::https_intercept_decision(request)?;
                log::info!(
                    "[bridge https-intercept] decision: handled={} status={}",
                    result.handled, result.status
                );
                event.respond(result)
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
            "print-state" => {
                // Fire-and-forget: non-blocking unbounded send; the consumer polls on a
                // worker thread (never recv on the main thread — deadlock precedent).
                let notification = event.decode::<WebviewPrintStateEvent>()?;
                let _ = print_state_channel().0.send(notification);
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
    /// Process-global scheme set sealed before ArkWeb initialization. A module activated after
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
    /// remains module-local and is never used as a process-global platform key.
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
    /// True when any drag callback (enter/over/drop/leave) is registered.
    pub drag_drop: bool,
    /// True when a new-window callback is registered.
    pub new_window: bool,
    /// True when a page-begin callback is registered.
    pub page_begin: bool,
    /// True when a page-end callback is registered.
    pub page_end: bool,
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
    /// the ArkTS host appends the WebView FrameNode under that container instead of this native
    /// module's DefaultXComponent root.
    pub parent_handle: Option<u32>,
    /// OHOS window ID for sub-window webview mounting. When non-zero, the webview's FrameNode
    /// is mounted into the specified window's component root (from WindowManager) instead of
    /// this module's DefaultXComponent root.
    pub window_id: Option<i64>,
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
    /// Enable ArkWeb native clipboard (Ctrl+C/V/X/A/Z/Y). Defaults to true (ArkWeb default).
    /// false disables native clipboard so accelerator_matcher can intercept clipboard shortcuts.
    pub clipboard: Option<bool>,
    /// Enable zoom hotkeys (Ctrl+/-/0). Defaults to false.
    pub zoom_hotkeys: Option<bool>,
    /// Use a transparent Stack overlay to receive drag events (instead of binding directly on the
    /// Web component). Defaults to false. Use when ArkWeb drag events are unreliable.
    pub drag_drop_overlay: Option<bool>,
    /// https-scheme protocols to intercept at create time. Seeds the ArkTS
    /// `httpsInterceptProtocols` Set before the first `loadUrl`, fixing the
    /// create-vs-register race that left the Set empty and caused `onInterceptRequest`
    /// to early-return null → ArkWeb fetched the consumer-registered custom protocol for real →
    /// `arkweb-error://webdata/` → `isSecureContext=false`. Late `register_https_intercept`
    /// remains as a runtime add path (Set.add is idempotent).
    pub https_intercept_protocol_list: Option<Vec<String>>,
    #[doc(hidden)]
    pub event_options: WebviewCallbackOptions,
}

impl_bridge_napi_type!(WebviewCreateRequest, "ohos.webview.CreateRequest");

impl WebviewCreateRequest {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            parent_handle: None,
            window_id: None,
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
            clipboard: None,
            zoom_hotkeys: None,
            drag_drop_overlay: None,
            https_intercept_protocol_list: None,
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

// ── https-intercept ─────────────────────────────────────────────────────────────

/// Synchronous https intercept request delivered from ArkWeb `onInterceptRequest`.
///
/// When the request URL matches `https://<protocol>.localhost/<path>` and `<protocol>` is in the
/// WebView's live protocol set, ArkTS dispatches this event synchronously through
/// `context.invokeNativeSync`. The Rust handler must produce a response before the NAPI environment
/// is released, because `onInterceptRequest` is a synchronous ArkWeb callback.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewHttpsInterceptRequest {
    pub id: String,
    /// Process-unique controller generation used to reject callbacks from a replaced WebView.
    pub native_tag: String,
    pub url: String,
}

impl_bridge_napi_type!(
    WebviewHttpsInterceptRequest,
    "ohos.webview.HttpsInterceptRequest"
);

/// Synchronous https intercept response. `handled: false` lets ArkWeb fall through to its default
/// network stack; `handled: true` returns the embedded response to ArkWeb.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewHttpsInterceptResponse {
    pub handled: bool,
    pub status: u16,
    pub mime_type: String,
    /// Raw response body bytes transported as `Uint8Array` across the NAPI boundary.
    pub body: Vec<u8>,
}

impl_bridge_napi_type!(
    WebviewHttpsInterceptResponse,
    "ohos.webview.HttpsInterceptResponse"
);

impl WebviewHttpsInterceptResponse {
    /// Returns the passthrough response: ArkWeb continues with its default network stack.
    pub fn passthrough() -> Self {
        Self {
            handled: false,
            status: 0,
            mime_type: String::new(),
            body: Vec::new(),
        }
    }
}

/// Outbound request that registers custom-protocol names for https interception on a WebView.
///
/// Rust (typically the webview consumer's `with_webview` hook) sends this async action so ArkTS merges the protocol
/// names into the WebView's live protocol set. Subsequent `onInterceptRequest` callbacks check this
/// set before dispatching through the bridge.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewRegisterHttpsInterceptRequest {
    pub id: String,
    pub protocols: Vec<String>,
}

impl_bridge_napi_type!(
    WebviewRegisterHttpsInterceptRequest,
    "ohos.webview.RegisterHttpsInterceptRequest"
);

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

// ── create-pdf ──────────────────────────────────────────────────────────────────

/// Optional PDF generation configuration, mirroring `webview.PdfConfiguration`.
/// Every field is optional — when `None`, the ArkTS side falls back to its
/// defaults (A4 8.27×11.69in, zero margins, background printing on).
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct WebviewPdfConfig {
    /// Page width in inches.
    pub width: Option<f64>,
    /// Page height in inches.
    pub height: Option<f64>,
    pub margin_top: Option<f64>,
    pub margin_bottom: Option<f64>,
    pub margin_left: Option<f64>,
    pub margin_right: Option<f64>,
    /// Page scale factor (e.g. 1.0).
    pub scale: Option<f64>,
    /// Whether to print background colors/images.
    pub should_print_background: Option<bool>,
}

/// Request to generate a PDF file from the current WebView page.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewPrintRequest {
    pub id: String,
    /// Target PDF file absolute path on the device filesystem.
    pub path: String,
    /// Optional PDF layout configuration. When absent the ArkTS side uses
    /// fixed A4 defaults; when present the provided values override per-field.
    pub pdf_config: Option<WebviewPdfConfig>,
}

impl_bridge_napi_type!(WebviewPrintRequest, "ohos.webview.PrintRequest");

/// Response for create-pdf. `success` indicates the PDF was written to `path`.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewPrintResponse {
    pub success: bool,
}

impl_bridge_napi_type!(WebviewPrintResponse, "ohos.webview.PrintResponse");

// ── print-state ─────────────────────────────────────────────────────────────────

/// Terminal state of an OHOS system print job (PrintTask event).
///
/// Pushed from ArkTS `WebviewPlugin.ets` PrintTask `.on("succeed"|"fail"|"cancel"|"block")`
/// handlers through the `print-state` main-thread event. Decoded on the NAPI main thread and
/// forwarded through a process-wide crossbeam channel — never blocked on from the main
/// thread (the consumer polls on a worker thread, see `print_state_receiver`).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewPrintStateEvent {
    /// The WebView id that initiated `printPdf` (correlation key for the consumer).
    pub id: String,
    /// One of: `"succeed"`, `"fail"`, `"cancel"`, `"block"`.
    pub state: String,
    /// Error message for `state == "fail"` (absent otherwise).
    pub error: Option<String>,
}

impl_bridge_napi_type!(WebviewPrintStateEvent, "ohos.webview.PrintStateEvent");

static PRINT_STATE_CHANNEL: OnceLock<(Sender<WebviewPrintStateEvent>, Receiver<WebviewPrintStateEvent>)> =
    OnceLock::new();

fn print_state_channel() -> &'static (Sender<WebviewPrintStateEvent>, Receiver<WebviewPrintStateEvent>) {
    PRINT_STATE_CHANNEL.get_or_init(unbounded)
}

/// Returns the process-wide receiver for OHOS print-job terminal-state events.
///
/// Each `printPdf` terminal state (`succeed`/`fail`/`cancel`/`block`) produces one event
/// carrying the originating WebView `id`. The receiver is `'static` and safe to poll on a
/// worker thread (do NOT `recv` on the NAPI main thread — that would deadlock). Consumer
/// pattern: spawn a thread, `while let Ok(event) = receiver.recv() { ... }`, then emit an
/// event to the embedding runtime via the app handle.
pub fn print_state_receiver() -> &'static Receiver<WebviewPrintStateEvent> {
    &print_state_channel().1
}

// ── web-page-snapshot ──────────────────────────────────────────────────────────

/// Request to capture a WebView snapshot (RGBA pixel data).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewSnapshotRequest {
    pub id: String,
}

impl_bridge_napi_type!(WebviewSnapshotRequest, "ohos.webview.SnapshotRequest");

/// Response for web-page-snapshot. `rgba_len` is the byte count of the RGBA
/// pixel buffer (width * height * 4), verified without transferring the full buffer.
/// The full RGBA is NOT sent across the bridge for efficiency (1.9MB for 800×600).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewSnapshotResponse {
    pub success: bool,
    pub width: u32,
    pub height: u32,
    pub rgba_len: u32,
}

impl_bridge_napi_type!(WebviewSnapshotResponse, "ohos.webview.SnapshotResponse");

// ── capture-webview / pick-color ────────────────────────────────────────────────

/// Response for `capture-webview`: the viewport snapshot (the on-screen area, not the
/// full scrollable page) encoded as a base64 PNG string plus its pixel dimensions.
/// base64 (not raw bytes) — a `Vec<u8>` in a napi object would
/// serialize as `Array<number>`, inflating a multi-hundred-KB PNG ~8x in memory.
/// Requests reuse [`WebviewControllerRequest`].
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewCaptureResponse {
    pub png_base64: String,
    pub width: u32,
    pub height: u32,
}

impl_bridge_napi_type!(WebviewCaptureResponse, "ohos.webview.CaptureResponse");

/// Response for `pick-color`: the pixel at snapshot coordinates (x, y). The ArkTS side
/// reads a 1px region via `readPixels` (which always outputs BGRA_8888 bytes regardless
/// of the PixelMap format) and converts the channels to RGBA before crossing the bridge.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewPickColorResponse {
    pub r: u32,
    pub g: u32,
    pub b: u32,
    pub a: u32,
}

impl_bridge_napi_type!(WebviewPickColorResponse, "ohos.webview.PickColorResponse");

// ── set-cookie ──────────────────────────────────────────────────────────────────

/// Request to set a cookie for a specific URL via `WebCookieManager.configCookieSync`.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewSetCookieRequest {
    pub id: String,
    pub url: String,
    /// Set-Cookie formatted value string (RFC 6265).
    pub value: String,
}

impl_bridge_napi_type!(WebviewSetCookieRequest, "ohos.webview.SetCookieRequest");

// ── set-user-agent ──────────────────────────────────────────────────────────────

/// Request to set the WebView's custom user agent string.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewUserAgentRequest {
    pub id: String,
    pub user_agent: String,
}

impl_bridge_napi_type!(WebviewUserAgentRequest, "ohos.webview.UserAgentRequest");

// ── drag events ─────────────────────────────────────────────────────────────────

/// Drag enter/over/leave event (no file paths; `getData()` is only valid in onDrop).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewDragEvent {
    pub id: String,
    pub native_tag: String,
    pub x: f64,
    pub y: f64,
}

impl_bridge_napi_type!(WebviewDragEvent, "ohos.webview.DragEvent");

/// Drop event carrying extracted file paths from UDMF records.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewDropEvent {
    pub id: String,
    pub native_tag: String,
    pub x: f64,
    pub y: f64,
    /// Extracted absolute file paths. Empty for enter/over/leave.
    pub paths: Vec<String>,
}

impl_bridge_napi_type!(WebviewDropEvent, "ohos.webview.DropEvent");

// ── new-window-request ──────────────────────────────────────────────────────────

/// Request delivered when ArkWeb asks to open a new window.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewNewWindowRequest {
    pub id: String,
    pub native_tag: String,
    pub target_url: String,
    pub is_alert: bool,
    pub is_user_trigger: bool,
}

impl_bridge_napi_type!(WebviewNewWindowRequest, "ohos.webview.NewWindowRequest");

/// Synchronous new-window decision.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewNewWindowResponse {
    pub allow: bool,
}

impl_bridge_napi_type!(WebviewNewWindowResponse, "ohos.webview.NewWindowResponse");

// ── page-begin / page-end ───────────────────────────────────────────────────────

/// Page navigation event (begin or end) carrying the page URL.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WebviewPageEvent {
    pub id: String,
    pub native_tag: String,
    pub url: String,
}

impl_bridge_napi_type!(WebviewPageEvent, "ohos.webview.PageEvent");

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

    /// Constructs a `WebviewClient` from an existing `BridgeRuntime` without requiring
    /// an `OpenHarmonyApp`. Used by the webview consumer's bridge-based webview backend where the runtime
    /// is passed through `PlatformSpecificWebViewAttributes::bridge_runtime`.
    pub fn from_bridge(bridge: BridgeRuntime) -> Self {
        Self { bridge }
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

    /// Reopens a controller-ID facade for a WebView already created in this module/session.
    pub fn handle(&self, id: impl Into<String>) -> WebviewHandle {
        WebviewHandle {
            client: self.clone(),
            id: id.into(),
        }
    }

    /// Declares a custom-scheme handler by module-local WebView ID before the ArkTS node is created.
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

    /// Registers custom-protocol names for https interception on the given WebView.
    ///
    /// This is the outbound companion to `WebviewCallbacksBuilder::on_https_intercept_request`.
    /// Typically called from the webview consumer's `with_webview` hook after the WebView has been created.
    pub async fn register_https_intercept(
        &self,
        webview_id: impl Into<String>,
        protocols: Vec<String>,
    ) -> Result<()> {
        let id = webview_id.into();
        self.bridge
            .call_async::<WebviewBridgePlugin, WebviewRegisterHttpsInterceptRequest, WebviewAcknowledgement>(
                "register-https-intercept",
                WebviewRegisterHttpsInterceptRequest { id, protocols },
                BridgeCallOptions::default(),
            )
            .await?
            .ensure()
    }

    async fn call<Request, Response>(&self, action: &str, request: Request) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.call_with_options(action, request, BridgeCallOptions::default())
            .await
    }

    /// Like [`call`] with an explicit per-call policy — heavy actions override the
    /// 15s default timeout via [`snapshot_call_options`].
    async fn call_with_options<Request, Response>(
        &self,
        action: &str,
        request: Request,
        options: BridgeCallOptions,
    ) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.bridge
            .call_async::<WebviewBridgePlugin, Request, Response>(action, request, options)
            .await
    }
}

/// Snapshot actions run a 10s-capped ArkWeb capture (up to 3 retries) plus, for
/// `capture-webview`, PNG packing of a potentially multi-MB image; give them a wider
/// budget than the 15s bridge default (aligned with the plugin-files/plugin-permission
/// precedent of 60s for heavy actions).
fn snapshot_call_options() -> BridgeCallOptions {
    BridgeCallOptions::default().with_timeout_ms(60_000)
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
            x: None,
            y: None,
            width: None,
            height: None,
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

    /// Registers custom-protocol names for https interception on this WebView.
    ///
    /// The protocols are merged into the ArkTS-side live protocol set. Subsequent
    /// `onInterceptRequest` callbacks matching `https://<protocol>.localhost/<path>` will be
    /// dispatched synchronously through the `https-intercept` bridge event. This is the outbound
    /// companion to the `WebviewCallbacksBuilder::on_https_intercept_request` Rust handler.
    pub async fn register_https_intercept(&self, protocols: Vec<String>) -> Result<()> {
        self.client
            .call::<_, WebviewAcknowledgement>(
                "register-https-intercept",
                WebviewRegisterHttpsInterceptRequest {
                    id: self.id.clone(),
                    protocols,
                },
            )
            .await?
            .ensure()
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

    /// Registers a page-begin callback via the ArkWeb C-API binding path.
    ///
    /// **Deprecated**: use `WebviewCallbacksBuilder::on_page_begin` instead. The bridge
    /// `page-begin` reverse event path is the unified route; both paths active will fire the
    /// callback twice. This C-API path will be removed in the B2 webview consumer rewrite.
    #[deprecated(
        since = "1.0.0-beta.0",
        note = "use WebviewCallbacksBuilder::on_page_begin via the bridge reverse-event path"
    )]
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

    /// Registers a page-end callback via the ArkWeb C-API binding path.
    ///
    /// **Deprecated**: use `WebviewCallbacksBuilder::on_page_end` instead. The bridge
    /// `page-end` reverse event path is the unified route; both paths active will fire the
    /// callback twice. This C-API path will be removed in the B2 webview consumer rewrite.
    #[deprecated(
        since = "1.0.0-beta.0",
        note = "use WebviewCallbacksBuilder::on_page_end via the bridge reverse-event path"
    )]
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

    /// Updates the WebView bounds (position + size) in vp units.
    pub async fn set_bounds(&self, x: f64, y: f64, width: f64, height: f64) -> Result<()> {
        self.acknowledge(
            "set-bounds",
            WebviewControllerRequest {
                x: Some(x),
                y: Some(y),
                width: Some(width),
                height: Some(height),
                ..self.controller_request()
            },
        )
        .await
    }

    /// Sets a cookie for the given URL using `WebCookieManager.configCookieSync`.
    /// `value` should be a Set-Cookie formatted string (RFC 6265).
    pub async fn set_cookie(&self, url: impl Into<String>, value: impl Into<String>) -> Result<()> {
        self.client
            .call::<_, WebviewAcknowledgement>(
                "set-cookie",
                WebviewSetCookieRequest {
                    id: self.id.clone(),
                    url: url.into(),
                    value: value.into(),
                },
            )
            .await?
            .ensure()
    }

    /// Prints a previously generated PDF file at `path` using `@ohos.print`.
    pub async fn print(&self, path: impl Into<String>) -> Result<()> {
        self.client
            .call::<_, WebviewAcknowledgement>(
                "print",
                WebviewPrintRequest {
                    id: self.id.clone(),
                    path: path.into(),
                    pdf_config: None,
                },
            )
            .await?
            .ensure()
    }

    /// Toggles `WebviewController.setWebDebuggingAccess` (process-global static).
    /// This is a bridge action because the old ArkTS ObjectRef path is no longer
    /// available in the bridge architecture.
    pub async fn set_web_debugging_access(&self, enabled: bool) -> Result<()> {
        self.acknowledge(
            "set-web-debugging-access",
            WebviewControllerRequest {
                visible: Some(enabled),
                ..self.controller_request()
            },
        )
        .await
    }

    /// Named replacement for the old `dispose` controller operation.
    pub async fn dispose(&self) -> Result<()> {
        self.remove().await
    }

    /// Generates a PDF from the currently loaded page and writes it to `path`.
    ///
    /// When `pdf_config` is provided, its values override the ArkTS-side defaults
    /// (A4 8.27×11.69in, zero margins, background printing on) per-field.
    /// The ArkTS side guards `createPdf()` with an API 14+ version check; on older
    /// devices it returns `success: false`. Callers should invoke this after
    /// `page-end` to ensure the page is fully loaded.
    pub async fn create_pdf(
        &self,
        path: impl Into<String>,
        pdf_config: Option<WebviewPdfConfig>,
    ) -> Result<()> {
        let response = self
            .client
            .call::<_, WebviewPrintResponse>(
                "create-pdf",
                WebviewPrintRequest {
                    id: self.id.clone(),
                    path: path.into(),
                    pdf_config,
                },
            )
            .await?;
        if response.success {
            Ok(())
        } else {
            Err(Error::from_reason(
                "WebView create-pdf failed (API 14+ required or page not loaded)",
            ))
        }
    }

    /// Captures a snapshot of the current WebView page as RGBA pixel data.
    ///
    /// The ArkTS side uses `WebviewController.webPageSnapshot()` with up to 3 retries
    /// and a 10s overall timeout. Returns the raw RGBA bytes and dimensions.
    /// Note: `rgba` is serialized as `Array<number>` via NAPI — callers must convert
    /// to `Uint8Array` on the JS side if needed.
    pub async fn web_page_snapshot(&self) -> Result<WebviewSnapshotResponse> {
        let response = self
            .client
            .call_with_options::<_, WebviewSnapshotResponse>(
                "web-page-snapshot",
                WebviewSnapshotRequest {
                    id: self.id.clone(),
                },
                snapshot_call_options(),
            )
            .await?;
        if response.success {
            Ok(response)
        } else {
            Err(Error::from_reason(
                "WebView web-page-snapshot failed (page not loaded or snapshot error)",
            ))
        }
    }

    /// Captures the current page as a base64-encoded PNG image with its dimensions.
    ///
    /// The ArkTS side uses the same `webPageSnapshot` retry+timeout wrapper as
    /// [`WebviewHandle::web_page_snapshot`], then packs the PixelMap as PNG via
    /// `image.ImagePacker`. The PixelMap and ImagePacker are released on the ArkTS side.
    pub async fn capture_webview(&self) -> Result<WebviewCaptureResponse> {
        self.client
            .call_with_options::<_, WebviewCaptureResponse>(
                "capture-webview",
                self.controller_request(),
                snapshot_call_options(),
            )
            .await
    }

    /// Reads the color of a single pixel at snapshot coordinates (x, y).
    ///
    /// Both coordinates are pixel offsets into the snapshot, i.e. the same coordinate
    /// system as the width/height returned by [`WebviewHandle::capture_webview`].
    /// Coordinates outside the snapshot surface reject with a structured error.
    pub async fn pick_color(&self, x: u32, y: u32) -> Result<WebviewPickColorResponse> {
        let mut request = self.controller_request();
        request.x = Some(x as f64);
        request.y = Some(y as f64);
        self.client
            .call_with_options::<_, WebviewPickColorResponse>(
                "pick-color",
                request,
                snapshot_call_options(),
            )
            .await
    }
    ///
    /// OHOS recommends setting the user agent in `onControllerAttached`; runtime dynamic
    /// setting is supported but may probabilistically fail. The ArkTS side wraps this in
    /// try-catch.
    pub async fn set_user_agent(&self, user_agent: impl Into<String>) -> Result<()> {
        self.client
            .call::<_, WebviewAcknowledgement>(
                "set-user-agent",
                WebviewUserAgentRequest {
                    id: self.id.clone(),
                    user_agent: user_agent.into(),
                },
            )
            .await?
            .ensure()
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
    /// Optional bounds x position (vp). Used by the `set-bounds` action.
    pub x: Option<f64>,
    /// Optional bounds y position (vp). Used by the `set-bounds` action.
    pub y: Option<f64>,
    /// Optional bounds width (vp). Used by the `set-bounds` action.
    pub width: Option<f64>,
    /// Optional bounds height (vp). Used by the `set-bounds` action.
    pub height: Option<f64>,
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
    fn create_request_accepts_optional_clipboard_and_drag_fields() {
        let request = WebviewCreateRequest::new("webview")
            .url("https://example.test");
        assert!(request.clipboard.is_none());
        assert!(request.zoom_hotkeys.is_none());
        assert!(request.drag_drop_overlay.is_none());
        // The fields exist and default to None in new().
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
        assert_eq!(
            <WebviewPrintRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.PrintRequest"
        );
        assert_eq!(
            <WebviewPrintResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.PrintResponse"
        );
        assert_eq!(
            <WebviewUserAgentRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.UserAgentRequest"
        );
        assert_eq!(
            <WebviewDragEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.DragEvent"
        );
        assert_eq!(
            <WebviewDropEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.DropEvent"
        );
        assert_eq!(
            <WebviewNewWindowRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.NewWindowRequest"
        );
        assert_eq!(
            <WebviewNewWindowResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.NewWindowResponse"
        );
        assert_eq!(
            <WebviewPageEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.PageEvent"
        );
        assert_eq!(
            <WebviewHttpsInterceptRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.HttpsInterceptRequest"
        );
        assert_eq!(
            <WebviewHttpsInterceptResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.HttpsInterceptResponse"
        );
        assert_eq!(
            <WebviewRegisterHttpsInterceptRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.webview.RegisterHttpsInterceptRequest"
        );
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

    // ── expect_engine_phase ───────────────────────────────────────────────

    #[test]
    fn expect_engine_phase_matches() {
        let event = WebviewEngineLifecycleEvent {
            phase: "before-init".to_string(),
            schemes: vec![],
        };
        assert!(expect_engine_phase(&event, "before-init").is_ok());
    }

    #[test]
    fn expect_engine_phase_mismatch_returns_error() {
        let event = WebviewEngineLifecycleEvent {
            phase: "initialized".to_string(),
            schemes: vec![],
        };
        assert!(expect_engine_phase(&event, "before-init").is_err());
    }

    // ── engine_scheme_pairs ──────────────────────────────────────────────

    #[test]
    fn engine_scheme_pairs_extracts_scheme_and_options() {
        let event = WebviewEngineLifecycleEvent {
            phase: "before-init".to_string(),
            schemes: vec![
                WebviewSchemeDeclaration { scheme: "tauri".to_string(), options: 1 },
                WebviewSchemeDeclaration { scheme: "myapp".to_string(), options: 2 },
            ],
        };
        let pairs = engine_scheme_pairs(&event);
        assert_eq!(pairs.len(), 2);
        assert_eq!(pairs[0], ("tauri".to_string(), 1u32));
        assert_eq!(pairs[1], ("myapp".to_string(), 2u32));
    }

    #[test]
    fn engine_scheme_pairs_empty_schemes() {
        let event = WebviewEngineLifecycleEvent {
            phase: "before-init".to_string(),
            schemes: vec![],
        };
        assert!(engine_scheme_pairs(&event).is_empty());
    }
}
