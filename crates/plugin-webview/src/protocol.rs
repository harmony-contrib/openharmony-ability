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
    sealed: bool,
    flushed: bool,
    engine_initialized: bool,
    /// Rust-owned declarations survive a controller remove/create cycle for the same WebView ID.
    declarations: BTreeMap<String, BTreeMap<String, ProtocolDeclaration>>,
    /// A controller-attached event is the earliest point where ArkWeb guarantees that a
    /// BrowserContext exists for a concrete Web component.
    /// Business WebView ID -> process-unique ArkWeb controller tag.
    attached_webviews: BTreeMap<String, String>,
    /// Per-native-tag installation bookkeeping prevents a concurrent declaration and
    /// controller-attached callback from registering the same handler twice, without allowing a
    /// stale controller completion to mark its replacement as installed.
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
        let options_bits = options.bits();
        if !scheme_registration_needed(&state, scheme, options_bits)? {
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
        if !state.sealed {
            return Err(Error::from_reason(
                "WebView scheme declarations must be sealed before platform registration",
            ));
        }
        CustomProtocol::register();
        state.flushed = true;
        Ok(())
    }

    pub(crate) fn seal_before_engine_init() -> Result<()> {
        let mut state = PROTOCOL_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
        state.sealed = true;
        Ok(())
    }

    pub(crate) fn validate_process_schemes(registered_schemes: &[(String, u32)]) -> Result<()> {
        let state = PROTOCOL_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
        ensure_schemes_registered(&state, registered_schemes)
    }

    pub(crate) fn mark_engine_initialized(registered_schemes: &[(String, u32)]) -> Result<()> {
        let mut state = PROTOCOL_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
        ensure_schemes_registered(&state, registered_schemes)?;
        if state.engine_initialized {
            return Ok(());
        }
        // A native module can be activated after another module initialized ArkWeb. Matching
        // schemes are already registered process-wide, so this module joins without calling the
        // pre-init platform API again. New or conflicting schemes were rejected above.
        state.sealed = true;
        state.flushed = true;
        state.engine_initialized = true;
        Ok(())
    }

    pub(crate) fn declared_schemes() -> Result<Vec<(String, u32)>> {
        let state = PROTOCOL_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
        Ok(state
            .schemes
            .iter()
            .map(|(scheme, options)| (scheme.clone(), *options))
            .collect())
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

fn ensure_schemes_registered(
    state: &ProtocolState,
    registered_schemes: &[(String, u32)],
) -> Result<()> {
    for (scheme, options) in &state.schemes {
        if registered_schemes
            .iter()
            .any(|(registered, registered_options)| {
                registered == scheme && registered_options == options
            })
        {
            continue;
        }
        return Err(Error::from_reason(format!(
            "WebView scheme '{scheme}' from this native module was not registered with matching options before the process-global engine initialized"
        )));
    }
    Ok(())
}

fn scheme_registration_needed(
    state: &ProtocolState,
    scheme: &str,
    options_bits: u32,
) -> Result<bool> {
    if let Some(existing) = state.schemes.get(scheme) {
        if *existing != options_bits {
            return Err(Error::from_reason(format!(
                "WebView scheme '{scheme}' was already registered with different options"
            )));
        }
        // Native module statics survive Ability recreation. Repeating the same declaration is a
        // no-op even after the process-global engine has started.
        return Ok(false);
    }
    if state.engine_initialized {
        return Err(Error::from_reason(format!(
            "WebView scheme '{scheme}' must be registered before Web engine initialization"
        )));
    }
    if state.sealed || state.flushed {
        return Err(Error::from_reason(format!(
            "WebView scheme '{scheme}' must be registered before WebviewBridgePlugin begins Web engine initialization"
        )));
    }
    Ok(true)
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

/// Declares a custom-scheme handler for a module-local WebView ID.
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
        let native_tag = state.attached_webviews.get(&webview_id).cloned();
        match native_tag {
            Some(native_tag)
                if is_new_declaration && reserve_installation(&mut state, &native_tag, &scheme) =>
            {
                Some((declaration, native_tag))
            }
            _ => {
                // Declarations are persistent. Treat a retry as idempotent so an application can
                // retry a failed create without replacing a closure that an existing controller
                // uses.
                None
            }
        }
    };

    if let Some((declaration, native_tag)) = declaration_to_install {
        install_and_record(&webview_id, &native_tag, declaration)?;
    }
    Ok(())
}

/// Flushes queued handlers for a controller whose ArkTS Web component has attached.
///
/// This is called from the scoped named N-API `controller-attached` event. It must complete before
/// ArkTS starts the initial load so a custom-scheme document and every first-page subresource are
/// handled by native Rust code.
pub(crate) fn on_controller_attached(webview_id: &str, native_tag: &str) -> Result<()> {
    validate_webview_id(webview_id)?;
    validate_webview_id(native_tag)?;
    let declarations = {
        let mut state = PROTOCOL_STATE
            .lock()
            .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
        if !state.engine_initialized {
            return Err(Error::from_reason(
                "WebView custom protocol handler cannot attach before Web engine initialization",
            ));
        }
        let previous_tag = state
            .attached_webviews
            .insert(webview_id.to_owned(), native_tag.to_owned());
        if let Some(previous_tag) = previous_tag.filter(|previous| previous != native_tag) {
            state.installing_schemes.remove(&previous_tag);
            state.installed_schemes.remove(&previous_tag);
        }
        let declared = state
            .declarations
            .get(webview_id)
            .map(|declarations| declarations.values().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        declared
            .into_iter()
            .filter(|declaration| reserve_installation(&mut state, native_tag, &declaration.scheme))
            .collect::<Vec<_>>()
    };

    for declaration in declarations {
        install_and_record(webview_id, native_tag, declaration)?;
    }
    Ok(())
}

/// Marks a controller detached while retaining declarations for a future controller with the same
/// WebView ID and matching native tag.
pub(crate) fn on_controller_removed(webview_id: &str, native_tag: &str) -> Result<()> {
    let mut state = PROTOCOL_STATE
        .lock()
        .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
    if state.attached_webviews.get(webview_id).map(String::as_str) != Some(native_tag) {
        return Ok(());
    }
    state.attached_webviews.remove(webview_id);
    state.installing_schemes.remove(native_tag);
    state.installed_schemes.remove(native_tag);
    Ok(())
}

/// Clears controller-generation state at component/session teardown while retaining declarations
/// and the process-global engine/scheme state for a later appearance.
pub(crate) fn clear_attached() -> Result<()> {
    let mut state = PROTOCOL_STATE
        .lock()
        .map_err(|_| Error::from_reason("Failed to clear WebView protocol controller state"))?;
    state.attached_webviews.clear();
    state.installing_schemes.clear();
    state.installed_schemes.clear();
    Ok(())
}

fn reserve_installation(state: &mut ProtocolState, native_tag: &str, scheme: &str) -> bool {
    if state
        .installed_schemes
        .get(native_tag)
        .is_some_and(|schemes| schemes.contains(scheme))
        || state
            .installing_schemes
            .get(native_tag)
            .is_some_and(|schemes| schemes.contains(scheme))
    {
        return false;
    }
    state
        .installing_schemes
        .entry(native_tag.to_owned())
        .or_default()
        .insert(scheme.to_owned())
}

fn install_and_record(
    webview_id: &str,
    native_tag: &str,
    declaration: ProtocolDeclaration,
) -> Result<()> {
    let scheme = declaration.scheme.clone();
    match install_declaration(native_tag, declaration) {
        Ok(()) => finish_installation(webview_id, native_tag, &scheme, true),
        Err(error) => {
            let _ = finish_installation(webview_id, native_tag, &scheme, false);
            Err(error)
        }
    }
}

fn finish_installation(
    webview_id: &str,
    native_tag: &str,
    scheme: &str,
    installed: bool,
) -> Result<()> {
    let mut state = PROTOCOL_STATE
        .lock()
        .map_err(|_| Error::from_reason("Failed to lock WebView protocol state"))?;
    let remove_installing_entry = state
        .installing_schemes
        .get_mut(native_tag)
        .map(|schemes| {
            schemes.remove(scheme);
            schemes.is_empty()
        })
        .unwrap_or(false);
    if remove_installing_entry {
        state.installing_schemes.remove(native_tag);
    }
    if installed && state.attached_webviews.get(webview_id).map(String::as_str) == Some(native_tag)
    {
        state
            .installed_schemes
            .entry(native_tag.to_owned())
            .or_default()
            .insert(scheme.to_owned());
    }
    Ok(())
}

fn install_declaration(native_tag: &str, declaration: ProtocolDeclaration) -> Result<()> {
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

    let attached = Web::new(native_tag.to_owned())
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
    use super::{
        ensure_schemes_registered, reserve_installation, scheme_registration_needed,
        validate_scheme, validate_webview_id, ProtocolState,
    };

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
        assert!(reserve_installation(&mut state, "native-tag-a", "asset"));
        assert!(!reserve_installation(&mut state, "native-tag-a", "asset"));
        assert!(reserve_installation(&mut state, "native-tag-b", "asset"));

        state.installing_schemes.clear();
        state
            .installed_schemes
            .entry("native-tag-a".to_owned())
            .or_default()
            .insert("asset".to_owned());
        assert!(!reserve_installation(&mut state, "native-tag-a", "asset"));
    }

    #[test]
    fn identical_scheme_registration_is_idempotent_after_engine_initialization() {
        let mut state = ProtocolState::default();
        state.schemes.insert("asset".to_owned(), 7);
        state.flushed = true;
        state.engine_initialized = true;

        assert!(!scheme_registration_needed(&state, "asset", 7).unwrap());
        assert!(scheme_registration_needed(&state, "asset", 8).is_err());
        assert!(scheme_registration_needed(&state, "late", 7).is_err());
    }

    #[test]
    fn late_module_can_join_only_with_process_registered_schemes() {
        let mut state = ProtocolState::default();
        state.schemes.insert("asset".to_owned(), 7);

        assert!(ensure_schemes_registered(&state, &[("asset".to_owned(), 7)]).is_ok());
        assert!(ensure_schemes_registered(&state, &[("asset".to_owned(), 8)]).is_err());
        assert!(ensure_schemes_registered(&state, &[]).is_err());
    }
}
