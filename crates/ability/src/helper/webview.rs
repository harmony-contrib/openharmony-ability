use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{Function, Object},
    Either, Error, Result,
};
use ohos_web_binding::Web;

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
        callback: Option<Box<dyn Fn(String) + Send + Sync + 'static>>,
    ) -> Result<()> {
        self.web_view_native
            .evaluate_js(String::from(js), callback)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        Ok(())
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
