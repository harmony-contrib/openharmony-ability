use std::{borrow::Cow, collections::HashMap, rc::Rc};

use http::{HeaderName, HeaderValue, Request, Response};
use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{FnArgs, Function, JsObjectValue, ObjectRef},
    Either, Error, Result,
};
use ohos_web_binding::{ArkWebResponse, CustomProtocolHandler, Web};

use crate::get_main_thread_env;

#[napi(object)]
#[derive(Debug, Clone, Default)]
pub struct WebViewStyle {
    pub x: Option<Either<f64, String>>,
    pub y: Option<Either<f64, String>>,
    pub visible: Option<bool>,
    pub background_color: Option<String>,
}

#[napi(object)]
#[derive(Default)]
pub struct DownloadStartResult {
    pub allow: bool,
    pub temp_path: Option<String>,
}

#[napi(object)]
#[derive(Default)]
pub struct WebViewInitData<'a> {
    pub url: Option<String>,
    pub id: Option<String>,
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
    pub on_download_start: Option<Function<'a, (String, String), DownloadStartResult>>,
    pub on_download_end: Option<Function<'a, (String, Option<String>, bool), ()>>,
    pub on_navigation_request: Option<Function<'a, String, bool>>,
    pub on_title_change: Option<Function<'a, String, ()>>,
}

#[derive(Clone)]
pub struct Webview {
    tag: String,
    inner: Rc<ObjectRef>,
    web_view_native: Rc<Web>,
}

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
                .get_value(&env)?
                .get_named_property::<Function<'_, (), String>>("getUrl")?;
            url_js_function.call(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    /// Load a url in the webview
    pub fn load_url(&self, url: &str) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let load_url_js_function = self.inner.get_value(&env)?.get_named_property::<Function<
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
                .get_value(&env)?
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
                .get_value(&env)?
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
                .get_value(&env)?
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
                .get_value(&env)?
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
                .get_value(&env)?
                .get_named_property::<Function<'_, (), ()>>("requestFocus")?;
            focus_js_function.call(())?;
            Ok(())
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
                .get_value(&env)?
                .get_named_property::<Function<'_, FnArgs<(String, Function<'_, String, ()>)>, ()>>(
                    "runJavaScript",
                )?;

            let cb = env.create_function_from_closure("evaluate_js_callback", move |ctx| {
                let ret = ctx.try_get::<String>(1)?;
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
                .get_value(&env)?
                .get_named_property::<Function<'_, String, String>>("getCookies")?;
            cookies_js_function.call(url.to_string())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    pub fn set_background_color(&self, color: &str) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let set_background_color_js_function = self
                .inner
                .get_value(&env)?
                .get_named_property::<Function<'_, String, ()>>("setBackgroundColor")?;
            set_background_color_js_function.call(color.to_string())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    pub fn set_visible(&self, visible: bool) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let set_visible_js_function = self
                .inner
                .get_value(&env)?
                .get_named_property::<Function<'_, bool, ()>>("setVisible")?;
            set_visible_js_function.call(visible)?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
    }

    pub fn clear_all_browsing_data(&self) -> Result<()> {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let clear_all_browsing_data_js_function = self
                .inner
                .get_value(&env)?
                .get_named_property::<Function<'_, (), ()>>("clearAllBrowsingData")?;
            clear_all_browsing_data_js_function.call(())?;
            Ok(())
        } else {
            Err(Error::from_reason("Failed to get main thread env"))
        }
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
        F: Fn(&str, Request<Vec<u8>>, bool) -> Option<Response<Cow<'static, [u8]>>>,
    {
        let handle = CustomProtocolHandler::new();
        let cbs = Box::leak(Box::new(callback));

        handle.on_request_start(|req, req_handle| {
            let url: String = req.url().into();
            let header = req.headers();
            let mut iter = header.iter();

            let request_body = req.http_body_stream();

            match request_body {
                Some(body) => {
                    let request_body_size = body.size();

                    body.read(request_body_size as usize, |buf| {
                        let mut request_builder = Request::builder()
                            .method(req.method().as_str())
                            .uri(url.clone());
                        while let Some((key, value)) = iter.next() {
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
                        let response = cbs(&url, request, req.is_main_frame());
                        if let Some(response) = response {
                            let header = response.headers();
                            let body = response.body();
                            let status = response.status();
                            let body_slice = match body {
                                Cow::Borrowed(slice) => slice,
                                Cow::Owned(vec) => vec.as_slice(),
                            };

                            let resp = ArkWebResponse::new();

                            header.iter().for_each(|(k, v)| {
                                resp.set_header(k.as_str(), v.to_str().unwrap_or_default(), true);
                            });

                            resp.set_status(status.as_u16() as _);

                            req_handle.receive_response(resp);
                            req_handle.receive_data(body_slice);
                            req_handle.finish();
                        }
                    });
                }
                None => {
                    let mut request_builder = Request::builder()
                        .method(req.method().as_str())
                        .uri(url.clone());
                    while let Some((key, value)) = iter.next() {
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
                    let response = cbs(&url, request, req.is_main_frame());
                    if let Some(response) = response {
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

                        req_handle.receive_response(resp);
                        req_handle.receive_data(body_slice);
                        req_handle.finish();
                    }
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
