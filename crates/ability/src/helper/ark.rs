use std::sync::Arc;

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Function, threadsafe_function::ThreadsafeFunction, Result};

use crate::WebViewInitData;

// Generates a JavaScript object that can be passed from ArkTS
#[napi(object)]
pub struct ArkTSHelper<'a> {
    pub exit: Function<'a, i32, ()>,
    pub create_webview: Function<'a, WebViewInitData, String>,
}

// Inner helper struct
pub struct ArkHelper {
    pub exit: Arc<ThreadsafeFunction<i32, ()>>,
    pub create_webview: Arc<ThreadsafeFunction<WebViewInitData, String>>,
}

impl ArkHelper {
    // Only called from main thread
    pub fn from_ark_ts_helper(helper: ArkTSHelper) -> Result<Self> {
        let exit = helper
            .exit
            .build_threadsafe_function()
            .callee_handled::<true>()
            .build()?;

        let create_webview = helper
            .create_webview
            .build_threadsafe_function()
            .callee_handled::<true>()
            .build()?;

        Ok(Self {
            exit: Arc::new(exit),
            create_webview: Arc::new(create_webview),
        })
    }
}

impl Clone for ArkHelper {
    fn clone(&self) -> Self {
        Self {
            exit: Arc::clone(&self.exit),
            create_webview: Arc::clone(&self.create_webview),
        }
    }
}
