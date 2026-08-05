//! Native custom-protocol support owned by the WebView capability crate.
//!
//! Scheme declarations are collected during the `#[ability]` initializer. `WebviewBridgePlugin`
//! flushes them immediately before ArkTS initializes the Web engine, which keeps the core bridge
//! unaware of WebView-specific global state.

use std::{
    borrow::Cow,
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, LazyLock, Mutex},
};

use http::{HeaderName, HeaderValue, Request, Response};
use napi_ohos::{Error, Result};
use ohos_web_binding::{ArkWebResponse, CustomProtocol, CustomProtocolHandler, Web};

type NativeResponse = Response<Cow<'static, [u8]>>;
type NativeRequest = Request<Vec<u8>>;
type Responder = Box<dyn FnOnce(NativeResponse)>;
type ProtocolCallback = Arc<
    dyn Fn(&str, WebviewProtocolRequest, bool, WebviewProtocolResponder) + Send + Sync + 'static,
>;

#[derive(Clone)]
struct ProtocolDeclaration {
    scheme: String,
    callback: ProtocolCallback,
}

#[derive(Default)]
struct ProtocolState {
    schemes: BTreeMap<String, u32>,
    flushed: bool,
    engine_initialized: bool,
    /// Rust-owned declarations survive a controller remove/create cycle for the same WebView tag.
    declarations: BTreeMap<String, BTreeMap<String, ProtocolDeclaration>>,
    /// A controller-attached event is the earliest point where ArkWeb guarantees that a
    /// BrowserContext exists for a concrete Web component.
    attached_webviews: BTreeSet<String>,
    /// Per-controller installation bookkeeping prevents a concurrent declaration and
    /// controller-attached callback from registering the same handler twice.
    installing_schemes: BTreeMap<String, BTreeSet<String>>,
    installed_schemes: BTreeMap<String, BTreeSet<String>>,
}

static PROTOCOL_STATE: LazyLock<Mutex<ProtocolState>> =
    LazyLock::new(|| Mutex::new(ProtocolState::default()));

/// ArkWeb scheme flags re-exported under the WebView plugin API.
pub use ohos_web_binding::CustomProtocolOption as WebviewProtocolOptions;

/// Registers a named custom-scheme declaration before ArkTS initializes the Web engine.
///
/// Call [`Self::register`] in the `#[ability]` initializer, before the `WebviewBridgePlugin` is
/// registered. The plugin flushes declarations at its `before-engine-init` event. Registering a
/// new scheme after the engine has started is rejected deterministically.
pub struct WebviewProtocol;

impl WebviewProtocol {
    pub fn register(scheme: impl AsRef<str>, options: WebviewProtocolOptions) -> Result<()> {
        let scheme = scheme.as_ref();
        validate_scheme(scheme)?;

        let mut state = PROTOCOL_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
        if state.engine_initialized {
            return Err(Error::from_reason(format!(
                "WebView scheme '{scheme}' must be registered before Web engine initialization"
            )));
        }
        if state.flushed {
            return Err(Error::from_reason(format!(
                "WebView scheme '{scheme}' must be registered before WebviewBridgePlugin begins Web engine initialization"
            )));
        }

        let options_bits = options.bits();
        if let Some(existing) = state.schemes.get(scheme) {
            if *existing != options_bits {
                return Err(Error::from_reason(format!(
                    "WebView scheme '{scheme}' was already registered with different options"
                )));
            }
            return Ok(());
        }

        CustomProtocol::add_protocol_with_option(scheme, options);
        state.schemes.insert(scheme.to_owned(), options_bits);
        Ok(())
    }

    pub(crate) fn flush_before_engine_init() -> Result<()> {
        let mut state = PROTOCOL_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
        if state.engine_initialized || state.flushed {
            return Ok(());
        }
        CustomProtocol::register();
        state.flushed = true;
        Ok(())
    }

    pub(crate) fn mark_engine_initialized() -> Result<()> {
        let mut state = PROTOCOL_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
        if !state.flushed {
            return Err(Error::from_reason(
                "WebView engine initialized before custom scheme declarations were flushed",
            ));
        }
        state.engine_initialized = true;
        Ok(())
    }

    fn require_declared(scheme: &str) -> Result<()> {
        validate_scheme(scheme)?;
        let state = PROTOCOL_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
        if !state.schemes.contains_key(scheme) {
            return Err(Error::from_reason(format!(
                "WebView scheme '{scheme}' was not declared with WebviewProtocol::register"
            )));
        }
        Ok(())
    }
}

/// An HTTP-style request delivered for a custom WebView scheme.
pub type WebviewProtocolRequest = NativeRequest;

/// An HTTP-style response consumed by a custom WebView scheme.
pub type WebviewProtocolResponse = NativeResponse;

/// One-shot responder for a custom-scheme request.
///
/// It is `Send` so an async application handler may resolve it on its own worker. ArkWeb owns the
/// underlying handle until the response is delivered.
pub struct WebviewProtocolResponder {
    responder: Responder,
}

unsafe impl Send for WebviewProtocolResponder {}

impl WebviewProtocolResponder {
    pub fn respond<T: Into<Cow<'static, [u8]>>>(self, response: Response<T>) {
        let (parts, body) = response.into_parts();
        (self.responder)(Response::from_parts(parts, body.into()));
    }
}

/// Declares a custom-scheme handler for a WebView tag.
///
/// The declaration may be made before the ArkTS node exists. The handler is attached only when
/// the Web component reports `controller-attached`, after ArkWeb has created its BrowserContext
/// and before the plugin performs the initial navigation. This keeps the first custom-scheme load
/// race-free without retaining an ArkTS object or calling ArkWeb before it is ready.
pub fn bind_custom_protocol<S, F>(
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
    bind_custom_protocol_async(
        webview_id,
        scheme,
        move |url, request, is_main_frame, responder| {
            if let Some(response) = callback(url, request, is_main_frame) {
                responder.respond(response);
            }
        },
    )
}

/// Asynchronous custom-scheme variant. The handler owns the responder and may resolve it later.
pub fn bind_custom_protocol_async<S, F>(
    webview_id: impl Into<String>,
    scheme: S,
    callback: F,
) -> Result<()>
where
    S: AsRef<str>,
    F: Fn(&str, WebviewProtocolRequest, bool, WebviewProtocolResponder) + Send + Sync + 'static,
{
    let webview_id = webview_id.into();
    let scheme = scheme.as_ref().to_owned();
    validate_webview_id(&webview_id)?;
    WebviewProtocol::require_declared(&scheme)?;

    let declaration = ProtocolDeclaration {
        scheme: scheme.clone(),
        callback: Arc::new(callback),
    };
    let declaration_to_install = {
        let mut state = PROTOCOL_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
        let is_new_declaration = {
            let declarations = state.declarations.entry(webview_id.clone()).or_default();
            if declarations.contains_key(&scheme) {
                false
            } else {
                declarations.insert(scheme.clone(), declaration.clone());
                true
            }
        };
        if is_new_declaration
            && state.attached_webviews.contains(&webview_id)
            && reserve_installation(&mut state, &webview_id, &scheme)
        {
            Some(declaration)
        } else {
            // Declarations are persistent. Treat a retry as idempotent so an application can
            // retry a failed create without replacing a closure that an existing controller uses.
            None
        }
    };

    if let Some(declaration) = declaration_to_install {
        install_and_record(&webview_id, declaration)?;
    }
    Ok(())
}

/// Flushes queued handlers for a controller whose ArkTS Web component has attached.
///
/// This is called from the scoped named N-API `controller-attached` event. It must complete before
/// ArkTS starts the initial load so a custom-scheme document and every first-page subresource are
/// handled by native Rust code.
pub(crate) fn on_controller_attached(webview_id: &str) -> Result<()> {
    validate_webview_id(webview_id)?;
    let declarations = {
        let mut state = PROTOCOL_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
        if !state.engine_initialized {
            return Err(Error::from_reason(
                "WebView custom protocol handler cannot attach before Web engine initialization",
            ));
        }
        state.attached_webviews.insert(webview_id.to_owned());
        let declared = state
            .declarations
            .get(webview_id)
            .map(|declarations| declarations.values().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        declared
            .into_iter()
            .filter(|declaration| reserve_installation(&mut state, webview_id, &declaration.scheme))
            .collect::<Vec<_>>()
    };

    for declaration in declarations {
        install_and_record(webview_id, declaration)?;
    }
    Ok(())
}

/// Marks a controller detached while retaining declarations for a future controller with the same
/// WebView tag.
pub(crate) fn on_controller_removed(webview_id: &str) -> Result<()> {
    let mut state = PROTOCOL_STATE
        .lock()
        .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
    state.attached_webviews.remove(webview_id);
    state.installing_schemes.remove(webview_id);
    state.installed_schemes.remove(webview_id);
    Ok(())
}

fn reserve_installation(state: &mut ProtocolState, webview_id: &str, scheme: &str) -> bool {
    if state
        .installed_schemes
        .get(webview_id)
        .is_some_and(|schemes| schemes.contains(scheme))
        || state
            .installing_schemes
            .get(webview_id)
            .is_some_and(|schemes| schemes.contains(scheme))
    {
        return false;
    }
    state
        .installing_schemes
        .entry(webview_id.to_owned())
        .or_default()
        .insert(scheme.to_owned())
}

fn install_and_record(webview_id: &str, declaration: ProtocolDeclaration) -> Result<()> {
    let scheme = declaration.scheme.clone();
    match install_declaration(webview_id, declaration) {
        Ok(()) => finish_installation(webview_id, &scheme, true),
        Err(error) => {
            let _ = finish_installation(webview_id, &scheme, false);
            Err(error)
        }
    }
}

fn finish_installation(webview_id: &str, scheme: &str, installed: bool) -> Result<()> {
    let mut state = PROTOCOL_STATE
        .lock()
        .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
    let remove_installing_entry = state
        .installing_schemes
        .get_mut(webview_id)
        .map(|schemes| {
            schemes.remove(scheme);
            schemes.is_empty()
        })
        .unwrap_or(false);
    if remove_installing_entry {
        state.installing_schemes.remove(webview_id);
    }
    if installed {
        state
            .installed_schemes
            .entry(webview_id.to_owned())
            .or_default()
            .insert(scheme.to_owned());
    }
    Ok(())
}

fn install_declaration(webview_id: &str, declaration: ProtocolDeclaration) -> Result<()> {
    let ProtocolDeclaration { scheme, callback } = declaration;
    let handler = CustomProtocolHandler::new();
    handler.on_request_start(move |request, request_handle| {
        let url = request.url();
        let method = request.method().as_str().to_owned();
        let headers = request.headers();
        let is_main_frame = request.is_main_frame();

        if let Some(body) = request.http_body_stream() {
            let callback = Arc::clone(&callback);
            let mut request_handle = Some(request_handle);
            body.read(body.size() as usize, move |body| {
                let Some(request_handle) = request_handle.take() else {
                    return;
                };
                let responder = responder_for(request_handle);
                match build_request(&method, &url, headers.iter(), body) {
                    Ok(native_request) => callback(&url, native_request, is_main_frame, responder),
                    Err(_) => responder.respond(invalid_request_response()),
                }
            });
        } else {
            let responder = responder_for(request_handle);
            match build_request(&method, &url, headers.iter(), Vec::new()) {
                Ok(native_request) => callback(&url, native_request, is_main_frame, responder),
                Err(_) => responder.respond(invalid_request_response()),
            }
        }
        true
    });

    let attached = Web::new(webview_id.to_owned())
        .custom_protocol(scheme, handler)
        .map_err(|error| {
            Error::from_reason(format!("Failed to bind WebView custom protocol: {error}"))
        })?;
    if attached {
        Ok(())
    } else {
        Err(Error::from_reason(
            "ArkWeb rejected the custom protocol handler for this WebView tag",
        ))
    }
}

fn build_request<'a>(
    method: &str,
    url: &str,
    headers: impl Iterator<Item = (&'a String, &'a String)>,
    body: Vec<u8>,
) -> std::result::Result<WebviewProtocolRequest, http::Error> {
    let mut builder = Request::builder().method(method).uri(url);
    for (key, value) in headers {
        if let (Ok(name), Ok(value)) = (
            HeaderName::from_bytes(key.as_bytes()),
            HeaderValue::from_bytes(value.as_bytes()),
        ) {
            builder = builder.header(name, value);
        }
    }
    builder.body(body)
}

fn invalid_request_response() -> WebviewProtocolResponse {
    let mut response = Response::new(Cow::Borrowed(&b"Invalid custom-scheme request"[..]));
    *response.status_mut() = http::StatusCode::BAD_REQUEST;
    response
}

fn responder_for(request_handle: ohos_web_binding::ResourceHandle) -> WebviewProtocolResponder {
    WebviewProtocolResponder {
        responder: Box::new(move |response| {
            let (parts, body) = response.into_parts();
            let response = ArkWebResponse::new();
            for (name, value) in &parts.headers {
                response.set_header(name.as_str(), value.to_str().unwrap_or_default(), true);
            }
            response.set_status(parts.status.as_u16() as _);
            request_handle.receive_response(response);
            request_handle.receive_data(body.as_ref());
            request_handle.finish();
        }),
    }
}

fn validate_scheme(scheme: &str) -> Result<()> {
    let mut bytes = scheme.bytes();
    let Some(first) = bytes.next() else {
        return Err(Error::from_reason("WebView scheme must not be empty"));
    };
    if !first.is_ascii_alphabetic()
        || !bytes.all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'-' | b'.'))
    {
        return Err(Error::from_reason(
            "WebView scheme must start with a letter and contain only ASCII letters, digits, '+', '-' or '.'",
        ));
    }
    Ok(())
}

fn validate_webview_id(webview_id: &str) -> Result<()> {
    if webview_id.trim().is_empty() {
        return Err(Error::from_reason(
            "WebView custom protocol id must not be empty",
        ));
    }
    if webview_id.contains('\0') {
        return Err(Error::from_reason(
            "WebView custom protocol id must not contain a NUL byte",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{reserve_installation, validate_scheme, validate_webview_id, ProtocolState};

    #[test]
    fn protocol_declarations_validate_scheme_and_webview_tag_before_arkweb() {
        assert!(validate_scheme("asset+v1").is_ok());
        assert!(validate_scheme("1asset").is_err());
        assert!(validate_webview_id("article-view").is_ok());
        assert!(validate_webview_id(" ").is_err());
        assert!(validate_webview_id("article\0view").is_err());
    }

    #[test]
    fn per_controller_installation_is_reserved_only_once() {
        let mut state = ProtocolState::default();
        assert!(reserve_installation(&mut state, "article", "asset"));
        assert!(!reserve_installation(&mut state, "article", "asset"));

        state.installing_schemes.clear();
        state
            .installed_schemes
            .entry("article".to_owned())
            .or_default()
            .insert("asset".to_owned());
        assert!(!reserve_installation(&mut state, "article", "asset"));
    }
}
