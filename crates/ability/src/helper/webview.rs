use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{FnArgs, Function, Object},
    Either, Error, JsString, Result,
};
use ohos_web_binding::Web;

use crate::get_main_thread_env;

#[napi(object)]
pub struct WebViewStyle {
    pub x: Option<Either<f64, String>>,
    pub y: Option<Either<f64, String>>,
}

#[napi(object)]
pub struct WebViewInitData {
    pub url: Option<String>,
    pub id: Option<String>,
    pub style: Option<WebViewStyle>,
}

pub struct Webview {
    tag: String,
    pub inner: Object,
    web_view_native: Web,
}

impl Webview {
    pub fn new(tag: String, inner: Object) -> Result<Self> {
        let native_instance =
            Web::new(tag.clone()).map_err(|e| Error::from_reason(e.to_string()))?;
        Ok(Self {
            inner,
            web_view_native: native_instance,
            tag,
        })
    }

    pub fn tag(&self) -> String {
        self.tag.clone()
    }

    /// Get the current url of the webview
    pub fn url(&self) -> Result<String> {
        let url_js_function = self
            .inner
            .get_named_property::<Function<'_, (), String>>("getUrl")?;
        url_js_function.call(())
    }

    /// Load a url in the webview
    pub fn load_url(&self, url: &str) -> Result<()> {
        let load_url_js_function = self
            .inner
            .get_named_property::<Function<'_, String, ()>>("loadUrl")?;

        load_url_js_function.call(url.to_string())?;
        Ok(())
    }

    /// Set the zoom level of the webview
    pub fn set_zoom(&self, zoom: f64) -> Result<()> {
        let set_zoom_js_function = self
            .inner
            .get_named_property::<Function<'_, f64, ()>>("zoom")?;
        set_zoom_js_function.call(zoom)?;
        Ok(())
    }

    /// Reload the webview
    pub fn reload(&self) -> Result<()> {
        let reload_js_function = self
            .inner
            .get_named_property::<Function<'_, (), ()>>("refresh")?;
        reload_js_function.call(())?;
        Ok(())
    }

    /// Focus the webview
    pub fn focus(&self) -> Result<()> {
        let focus_js_function = self
            .inner
            .get_named_property::<Function<'_, (), ()>>("requestFocus")?;
        focus_js_function.call(())?;
        Ok(())
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
            let evaluate_js_js_function = self.inner.get_named_property::<Function<
                '_,
                FnArgs<(String, Function<'_, String, ()>)>,
                (),
            >>("runJavaScript")?;

            let cb = env.create_function_from_closure("evaluate_js_callback", move |ctx| {
                let ret = ctx.try_get::<JsString>(1)?;
                let ret = match ret {
                    Either::A(ret) => ret.into_utf8()?.as_str()?.to_string(),
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
        let cookies_js_function = self
            .inner
            .get_named_property::<Function<'_, String, String>>("getCookies")?;
        cookies_js_function.call(url.to_string())
    }

    pub fn set_background_color(&self, color: &str) -> Result<()> {
        let set_background_color_js_function = self
            .inner
            .get_named_property::<Function<'_, String, ()>>("setBackgroundColor")?;
        set_background_color_js_function.call(color.to_string())?;
        Ok(())
    }

    pub fn set_visible(&self, visible: bool) -> Result<()> {
        let set_visible_js_function = self
            .inner
            .get_named_property::<Function<'_, bool, ()>>("setVisible")?;
        set_visible_js_function.call(visible)?;
        Ok(())
    }
}

#[cfg(feature = "webview")]
pub fn create_webview_with_id(url: &str, id: &str) -> Result<Webview> {
    let ret = unsafe {
        use crate::get_helper;
        get_helper()
    };
    if let Some(h) = ret.borrow().as_ref() {
        use napi_ohos::JsObject;

        use crate::get_main_thread_env;

        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let ret = h.get_value(&env)?;
            let create_webview_func =
                ret.get_named_property::<Function<'_, WebViewInitData, JsObject>>("createWebview")?;
            let webview = create_webview_func.call(WebViewInitData {
                url: Some(url.to_string()),
                id: Some(id.to_string()),
                style: None,
            })?;
            let web = Webview::new(String::from(id), webview)?;
            return Ok(web);
        }

        return Err(Error::from_reason("Failed to create webview"));
    }
    Err(Error::from_reason("Failed to create webview"))
}
