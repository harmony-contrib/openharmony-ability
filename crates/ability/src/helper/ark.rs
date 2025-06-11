use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::{Function, Object};

use crate::WebViewInitData;

// Generates a JavaScript object that can be passed from ArkTS
#[napi(object)]
pub struct ArkTSHelper<'a> {
    pub exit: Function<'a, i32, ()>,
    pub create_webview: Function<'a, WebViewInitData, Object>,
    pub hello: Function<'a, (), ()>,
}
