use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{Function, Object},
    Either, Result,
};

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
    inner: Object,
}

impl Webview {
    pub fn new(inner: Object) -> Self {
        Self { inner }
    }

    pub fn load_url(&self, url: &str) -> Result<()> {
        let load_url_js_function = self
            .inner
            .get_named_property::<Function<'_, String, ()>>("loadUrl")?;

        load_url_js_function.call(url.to_string())?;
        Ok(())
    }
}
