use std::{
    borrow::Cow,
    collections::HashMap,
    rc::Rc,
    sync::{Arc, Mutex},
};

use http::{HeaderName, HeaderValue, Request, Response};
use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{
        CallbackContext, FnArgs, Function, JsObjectValue, JsValue, Object, ObjectRef, PromiseRaw,
        Uint8Array, Unknown,
    },
    Either, Error, Result,
};
use ohos_web_binding::{ArkWebResponse, CustomProtocolHandler, Web};

use crate::get_main_thread_env;

/// Snapshot result returned by `web_page_snapshot()`.
/// Contains RGBA pixel data and dimensions.
pub struct SnapshotData {
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

#[napi(object)]
#[derive(Debug, Clone, Default)]
pub struct WebViewStyle {
    pub x: Option<Either<f64, String>>,
    pub y: Option<Either<f64, String>>,
    pub width: Option<Either<f64, String>>,
    pub height: Option<Either<f64, String>>,
    pub visible: Option<bool>,
    pub background_color: Option<u32>,
}

#[derive(Default, Clone, Debug)]
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

impl PdfConfig {
    /// Convert to HashMap for NAPI transport. Only includes fields that are Some.
    /// Keys use camelCase to match ArkTS PdfConfiguration naming.
    pub fn to_napi_map(&self) -> HashMap<String, Either<f64, bool>> {
        let mut map = HashMap::new();
        if let Some(v) = self.width {
            map.insert("width".to_string(), Either::A(v));
        }
        if let Some(v) = self.height {
            map.insert("height".to_string(), Either::A(v));
        }
        if let Some(v) = self.margin_top {
            map.insert("marginTop".to_string(), Either::A(v));
        }
        if let Some(v) = self.margin_bottom {
            map.insert("marginBottom".to_string(), Either::A(v));
        }
        if let Some(v) = self.margin_left {
            map.insert("marginLeft".to_string(), Either::A(v));
        }
        if let Some(v) = self.margin_right {
            map.insert("marginRight".to_string(), Either::A(v));
        }
        if let Some(v) = self.scale {
            map.insert("scale".to_string(), Either::A(v));
        }
        if let Some(v) = self.should_print_background {
            map.insert("shouldPrintBackground".to_string(), Either::B(v));
        }
        map
    }
}

#[napi(object)]
#[derive(Default)]
pub struct DownloadStartResult {
    pub allow: bool,
    pub temp_path: Option<String>,
}

/// Result of the `on_window_new` NAPI callback.
/// ArkTS reads `allow` to decide whether to call `setWebController(ctrl)` or `setWebController(null)`.
#[napi(object)]
#[derive(Debug, Clone, Default)]
pub struct OnWindowNewResult {
    pub allow: bool,
}

type OnDownloadStart<'a> = Option<Function<'a, (String, String), DownloadStartResult>>;
type OnDownloadEnd<'a> = Option<Function<'a, (String, Option<String>, bool), ()>>;
type OnWindowNew<'a> = Option<Function<'a, (String, bool, bool), OnWindowNewResult>>;

#[napi(object)]
#[derive(Default)]
pub struct WebViewInitData<'a> {
    pub url: Option<String>,
    pub id: Option<String>,
    pub window_id: Option<i64>,
    pub style: Option<WebViewStyle>,
    pub javascript_enabled: Option<bool>,
    pub devtools: Option<bool>,
    pub user_agent: Option<String>,
    pub autoplay: Option<bool>,
    pub initialization_scripts: Option<Vec<String>>,
    pub headers: Option<HashMap<String, String>>,
    pub html: Option<String>,
    pub transparent: Option<bool>,

    pub on_drag_and_drop: Option<Function<'a, String, ()>>,
    pub on_download_start: OnDownloadStart<'a>,
    pub on_download_end: OnDownloadEnd<'a>,
    pub on_navigation_request: Option<Function<'a, String, bool>>,
    pub on_title_change: Option<Function<'a, String, ()>>,
    pub on_page_begin: Option<Function<'a, String, ()>>,
    pub on_page_end: Option<Function<'a, String, ()>>,
    pub on_window_new: OnWindowNew<'a>,
}

#[derive(Clone)]
pub struct Webview {
    tag: String,
    inner: Rc<ObjectRef>,
    web_view_native: Rc<Web>,
}

// Safety: Webview is only ever used on the main thread (created in wry event loop,
// accessed via WithWebview handler on main thread). Rc<ObjectRef> does not cross
// thread boundaries in practice. This matches the pattern used by SendableHelper,
// CustomProtocolResponder, and OpenHarmonyApp in this codebase.
unsafe impl Send for Webview {}

impl Webview {
    pub fn new(tag: String, inner: ObjectRef) -> Result<Self> {
        let native_instance = Web::new(tag.clone());
        Ok(Self {
            inner: Rc::new(inner),
            web_view_native: Rc::new(native_instance),
            tag,
        })
    }

    pub fn inner(&self) -> Rc<ObjectRef> {
        self.inner.clone()
    }

    pub fn tag(&self) -> String {
        self.tag.clone()
    }

    /// Get the current url of the webview
    pub fn url(&self) -> Result<String> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let url_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, (), String>>("getUrl")?;
            url_js_function.call(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Load a url in the webview
    pub fn load_url(&self, url: &str) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let load_url_js_function = self.inner.get_value(env)?.get_named_property::<Function<
                '_,
                FnArgs<(String, Option<HashMap<String, String>>)>,
                (),
            >>("loadUrl")?;

            load_url_js_function.call((url.to_string(), None).into())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Load a url with headers in the webview
    pub fn load_url_with_headers(&self, url: &str, headers: http::HeaderMap) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let load_url_with_headers_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, FnArgs<(String, HashMap<String, String>)>, ()>>(
                    "loadUrl",
                )?;

            let headers = headers
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_str().unwrap_or_default().to_string()))
                .collect();
            load_url_with_headers_js_function.call((url.to_string(), headers).into())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Load html in the webview
    pub fn load_html(&self, html: &str) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let load_html_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, String, ()>>("loadHtml")?;
            load_html_js_function.call(html.to_string())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Set the zoom level of the webview
    pub fn set_zoom(&self, zoom: f64) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let set_zoom_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, f64, ()>>("zoom")?;
            set_zoom_js_function.call(zoom)?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Reload the webview
    pub fn reload(&self) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let reload_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, (), ()>>("refresh")?;
            reload_js_function.call(())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Focus the webview
    pub fn focus(&self) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let focus_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, (), ()>>("requestFocus")?;
            focus_js_function.call(())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Set web debugging access via `WebviewController.setWebDebuggingAccess`
    /// (a static global setter). The state is tracked ArkTS-side (OHOS has no
    /// getter). `open_devtools`/`close_devtools` map to this.
    pub fn set_web_debugging_access(&self, enabled: bool) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let set_debugging_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, bool, ()>>("setWebDebuggingAccess")?;
            set_debugging_js_function.call(enabled)?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Query the tracked web debugging access state. OHOS has no getter for
    /// `setWebDebuggingAccess`, so this returns the ArkTS-side tracked value.
    pub fn is_web_debugging_access(&self) -> Result<bool> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let is_debugging_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, (), bool>>("isWebDebuggingAccess")?;
            is_debugging_js_function.call(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    pub fn evaluate_script(&self, js: &str) -> Result<()> {
        self.evaluate_script_with_callback(js, None)
    }

    pub fn evaluate_script_with_callback(
        &self,
        js: &str,
        callback: Option<Box<dyn Fn(String) + Send + 'static>>,
    ) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let evaluate_js_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, FnArgs<(String, Function<'_, String, ()>)>, ()>>(
                    "runJavaScript",
                )?;

            let cb = env.create_function_from_closure("evaluate_js_callback", move |ctx| {
                let ret = ctx.try_get::<String>(0)?;
                let ret = match ret {
                    Either::A(s) => s,
                    Either::B(_ret) => String::from("undefined"),
                };
                if let Some(cb) = callback.as_ref() {
                    cb(ret);
                }
                Ok(())
            })?;

            evaluate_js_js_function.call((js.to_string(), cb).into())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    pub fn cookies_with_url(&self, url: &str) -> Result<String> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let cookies_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, String, String>>("getCookies")?;
            cookies_js_function.call(url.to_string())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Set a single cookie for the given url via `WebCookieManager.configCookieSync`.
    /// `value` must follow the Set-Cookie format (e.g. `name=value; Domain=...; Path=...`).
    pub fn set_cookie(&self, url: String, value: String) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let set_cookie_js_function = self.inner.get_value(env)?.get_named_property::<Function<
                '_,
                FnArgs<(String, String)>,
                (),
            >>("setCookie")?;
            set_cookie_js_function.call((url, value).into())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    pub fn set_background_color(&self, color: u32) -> Result<()> {
        crate::debug!(
            "[openharmony-ability] set_background_color(0x{:08X})",
            color
        );
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let set_background_color_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, u32, ()>>("setBackgroundColor")?;
            match set_background_color_js_function.call(color) {
                Ok(_) => Ok(()),
                Err(e) => {
                    crate::error!("[openharmony-ability] setBackgroundColor failed: {:?}", e);
                    Err(e)
                }
            }
        } else {
            crate::error!("[openharmony-ability] Failed to get main thread env");
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    pub fn set_visible(&self, visible: bool) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let set_visible_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, bool, ()>>("setVisible")?;
            set_visible_js_function.call(visible)?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    pub fn set_bounds(&self, x: f64, y: f64, width: f64, height: f64) -> Result<()> {
        crate::debug!(
            "[openharmony-ability] set_bounds({}, {}, {}, {})",
            x,
            y,
            width,
            height
        );
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let set_bounds_js_function = self.inner.get_value(env)?.get_named_property::<Function<
                '_,
                FnArgs<(f64, f64, f64, f64)>,
                (),
            >>("setBounds")?;
            set_bounds_js_function.call((x, y, width, height).into())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    pub fn dispose(&self) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let dispose_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, (), ()>>("dispose")?;
            dispose_js_function.call(())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    pub fn clear_all_browsing_data(&self) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let clear_all_browsing_data_js_function = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, (), ()>>("clearAllBrowsingData")?;
            clear_all_browsing_data_js_function.call(())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Capture a full-page snapshot of the web content as RGBA bitmap data.
    ///
    /// Calls the ArkTS `webPageSnapshot()` method which uses OHOS
    /// `WebviewController.webPageSnapshot()` API (API 12+).
    /// The callback fires asynchronously when the snapshot is ready.
    ///
    /// # Arguments
    /// * `callback` - Called with `Ok(SnapshotData)` on success, `Err` on failure.
    pub fn web_page_snapshot(
        &self,
        callback: impl FnOnce(std::result::Result<SnapshotData, String>) + 'static,
    ) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let snapshot_fn = self
                .inner
                .get_value(env)?
                .get_named_property::<Function<'_, (), Unknown<'_>>>("webPageSnapshot")?;

            let cb = Rc::new(std::cell::Cell::new(Some(callback)));
            let cb_catch = cb.clone();

            let result = snapshot_fn.call(())?;
            let promise: PromiseRaw<'static, Unknown<'static>> = unsafe { result.cast()? };
            promise
                .then(move |ctx: CallbackContext<Unknown>| {
                    let snapshot_data = (|| -> std::result::Result<SnapshotData, String> {
                        let obj: Object<'_> = unsafe { ctx.value.cast() }
                            .map_err(|e| format!("Failed to cast to Object: {}", e))?;
                        let rgba_arr = obj
                            .get_named_property::<Uint8Array>("rgba")
                            .map_err(|e| format!("Failed to get rgba: {}", e))?;
                        let width = obj
                            .get_named_property::<u32>("width")
                            .map_err(|e| format!("Failed to get width: {}", e))?;
                        let height = obj
                            .get_named_property::<u32>("height")
                            .map_err(|e| format!("Failed to get height: {}", e))?;
                        Ok(SnapshotData {
                            rgba: rgba_arr.to_vec(),
                            width,
                            height,
                        })
                    })();

                    if let Some(cb) = cb.replace(None) {
                        cb(snapshot_data);
                    }
                    Ok(())
                })?
                .catch(move |ctx: CallbackContext<Unknown>| {
                    let reason = ctx
                        .value
                        .coerce_to_string()
                        .and_then(|s| s.into_utf8().and_then(|u| u.into_owned()))
                        .unwrap_or_else(|_| "unknown rejection".to_string());
                    if let Some(cb) = cb_catch.replace(None) {
                        cb(Err(format!("webPageSnapshot rejected: {}", reason)));
                    }
                    Ok(())
                })?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Generates a PDF of the current web content and writes it to `path`.
    ///
    /// IMPORTANT: Must only be called after the page has fully loaded
    /// (i.e., after onPageEnd fires). Calling earlier produces a blank
    /// or incomplete PDF.
    ///
    /// # Callback contract
    /// - On success: `callback(true)` is called after the file is written
    /// - On early errors (invalid env, missing NAPI function): `callback(false)` is called before returning `Err`
    /// - On catastrophic NAPI failures (closure creation or call fails after callback is moved):
    ///   the callback is dropped without invocation. This is unrecoverable.
    pub fn create_pdf(
        &self,
        path: &str,
        config: Option<PdfConfig>,
        callback: Box<dyn Fn(bool) + Send + 'static>,
    ) -> Result<()> {
        let binding = get_main_thread_env();
        let borrowed = binding.borrow();
        let env = match borrowed.as_ref() {
            Some(env) => env,
            None => {
                callback(false);
                return Err(Error::from_reason("Failed to get main thread env"));
            }
        };

        let config_map = config.unwrap_or_default().to_napi_map();

        let create_pdf_fn = match self.inner.get_value(env) {
            Ok(v) => v,
            Err(e) => {
                callback(false);
                return Err(e);
            }
        };

        let create_pdf_fn = match create_pdf_fn.get_named_property::<Function<
            '_,
            FnArgs<(
                String,
                HashMap<String, Either<f64, bool>>,
                Function<'_, bool, ()>,
            )>,
            (),
        >>("createPdf")
        {
            Ok(f) => f,
            Err(e) => {
                callback(false);
                return Err(e);
            }
        };

        // callback is moved into the NAPI closure below.
        // If create_function_from_closure or call() fails after this point,
        // the callback cannot be invoked — these are catastrophic NAPI failures.
        let cb = env.create_function_from_closure("create_pdf_callback", move |ctx| {
            // napi-ohos try_get returns Either<T, JsUnknown>; Either::B covers
            // the case where the ArkTS callback passes a non-bool (e.g. undefined).
            let success = ctx.try_get::<bool>(0)?;
            let success = match success {
                Either::A(b) => b,
                Either::B(_) => false,
            };
            callback(success);
            Ok(())
        })?;

        create_pdf_fn.call((path.to_string(), config_map, cb).into())?;
        Ok(())
    }

    pub fn on_controller_attach<F>(&self, callback: F) -> Result<()>
    where
        F: FnMut(),
    {
        self.web_view_native
            .on_controller_attach(callback)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        Ok(())
    }

    pub fn on_page_begin<F>(&self, callback: F) -> Result<()>
    where
        F: FnMut(),
    {
        self.web_view_native
            .on_page_begin(callback)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        Ok(())
    }

    pub fn on_page_end<F>(&self, callback: F) -> Result<()>
    where
        F: FnMut(),
    {
        self.web_view_native
            .on_page_end(callback)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        Ok(())
    }

    pub fn on_destroy<F>(&self, callback: F) -> Result<()>
    where
        F: FnMut(),
    {
        self.web_view_native
            .on_destroy(callback)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        Ok(())
    }

    pub fn custom_protocol<S, F>(&self, protocol: S, callback: F) -> Result<()>
    where
        S: Into<String>,
        F: Fn(&str, Request<Vec<u8>>, bool) -> Option<Response<Cow<'static, [u8]>>> + 'static,
    {
        self.custom_protocol_async(protocol, move |url, request, is_main_frame, responder| {
            let response = callback(url, request, is_main_frame);
            if let Some(response) = response {
                responder.respond(response);
            }
        })
    }

    pub fn custom_protocol_async<S, F>(&self, protocol: S, callback: F) -> Result<()>
    where
        S: Into<String>,
        F: Fn(&str, Request<Vec<u8>>, bool, CustomProtocolResponder) + 'static,
    {
        let handle = CustomProtocolHandler::new();
        let cbs: &'static F = Box::leak(Box::new(callback));
        let cbs = Arc::new(Mutex::new(cbs));

        handle.on_request_start(move |req, req_handle| {
            let url: String = req.url();
            let header = req.headers();
            let mut iter = header.iter();

            let request_body = req.http_body_stream();

            let mut req_handle = Some(req_handle);

            match request_body {
                Some(body) => {
                    let request_body_size = body.size();

                    let cbs = cbs.clone();
                    body.read(request_body_size as usize, move |buf| {
                        let mut request_builder = Request::builder()
                            .method(req.method().as_str())
                            .uri(url.clone());
                        for (key, value) in iter.by_ref() {
                            if let (Ok(header), Ok(value)) = (
                                HeaderName::from_bytes(key.as_bytes()),
                                HeaderValue::from_bytes(value.as_bytes()),
                            ) {
                                request_builder = request_builder.header(header, value);
                            }
                        }
                        let request = request_builder
                            .body(buf)
                            .expect("Create http:Request failed");

                        let cbs = cbs.clone();
                        let req_handle = req_handle.take().unwrap();
                        let responder = CustomProtocolResponder {
                            responder: Box::new(move |response| {
                                let header = response.headers();
                                let body = response.body();
                                let status = response.status();
                                let body_slice = match body {
                                    Cow::Borrowed(slice) => slice,
                                    Cow::Owned(vec) => vec.as_slice(),
                                };

                                let resp = ArkWebResponse::new();

                                header.iter().for_each(|(k, v)| {
                                    resp.set_header(
                                        k.as_str(),
                                        v.to_str().unwrap_or_default(),
                                        true,
                                    );
                                });

                                resp.set_status(status.as_u16() as _);

                                req_handle.receive_response(resp);
                                req_handle.receive_data(body_slice);
                                req_handle.finish()
                            }),
                        };

                        let cb = *cbs.lock().unwrap();
                        cb(&url, request, req.is_main_frame(), responder);
                    });
                }
                None => {
                    let mut request_builder = Request::builder()
                        .method(req.method().as_str())
                        .uri(url.clone());
                    for (key, value) in iter {
                        if let (Ok(header), Ok(value)) = (
                            HeaderName::from_bytes(key.as_bytes()),
                            HeaderValue::from_bytes(value.as_bytes()),
                        ) {
                            request_builder = request_builder.header(header, value);
                        }
                    }
                    let request = request_builder
                        .body(vec![])
                        .expect("Create http:Request failed");

                    let responder = CustomProtocolResponder {
                        responder: Box::new(move |response| {
                            let header = response.headers();
                            let status = response.status();
                            let body = response.body();
                            let body_slice = match body {
                                Cow::Borrowed(slice) => slice,
                                Cow::Owned(vec) => vec.as_slice(),
                            };

                            let resp = ArkWebResponse::new();

                            header.iter().for_each(|(k, v)| {
                                resp.set_header(k.as_str(), v.to_str().unwrap_or_default(), true);
                            });
                            resp.set_status(status.as_u16() as _);

                            let req_handle = req_handle.take().unwrap();
                            req_handle.receive_response(resp);
                            req_handle.receive_data(body_slice);
                            req_handle.finish();
                        }),
                    };
                    let cb = *cbs.lock().unwrap();
                    cb(&url, request, req.is_main_frame(), responder);
                }
            }

            true
        });

        self.web_view_native
            .custom_protocol(protocol, handle)
            .map_err(|e| Error::from_reason(e.to_string()))?;

        Ok(())
    }
}

type Responder = Box<dyn FnOnce(Response<Cow<'static, [u8]>>)>;

pub struct CustomProtocolResponder {
    pub(crate) responder: Responder,
}

unsafe impl Send for CustomProtocolResponder {}

impl CustomProtocolResponder {
    /// Resolves the request with the given response.
    pub fn respond<T: Into<Cow<'static, [u8]>>>(self, response: Response<T>) {
        let (parts, body) = response.into_parts();
        (self.responder)(Response::from_parts(parts, body.into()))
    }
}
