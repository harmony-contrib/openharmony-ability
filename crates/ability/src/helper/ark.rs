use std::sync::Arc;

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Function, threadsafe_function::ThreadsafeFunction, Env, Result};

// Generates a JavaScript object that can be passed from ArkTS
#[napi(object)]
pub struct ArkTSHelper<'a> {
    pub exit: Function<'a, i32, ()>,
}

// Inner helper struct
pub struct ArkHelper {
    pub exit: Arc<ThreadsafeFunction<i32, ()>>,
}

impl ArkHelper {
    // Only called from main thread
    pub fn from_ark_ts_helper(helper: ArkTSHelper) -> Result<Self> {
        let exit = helper
            .exit
            .build_threadsafe_function()
            .callee_handled::<true>()
            .build()?;
        Ok(Self {
            exit: Arc::new(exit),
        })
    }
}

impl Clone for ArkHelper {
    fn clone(&self) -> Self {
        Self {
            exit: Arc::clone(&self.exit),
        }
    }
}
