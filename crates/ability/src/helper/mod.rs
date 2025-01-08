use napi_ohos::{threadsafe_function::ThreadsafeFunctionCallMode, Status};
use ohos_display_binding::default_display_scaled_density;

mod ark;
mod window_info;

pub use ark::*;

pub(crate) struct Helper {
    #[allow(dead_code)]
    pub(crate) ark: Option<ArkHelper>,
}

impl Clone for Helper {
    fn clone(&self) -> Self {
        Helper {
            ark: self.ark.clone(),
        }
    }
}

impl Default for Helper {
    fn default() -> Self {
        Helper { ark: None }
    }
}

impl Helper {
    pub fn new() -> Self {
        Helper { ark: None }
    }

    pub fn scale(&self) -> f32 {
        default_display_scaled_density()
    }

    /// exit current app
    pub fn exit(&self, code: u32) -> i32 {
        if let Some(ark) = self.ark.as_ref() {
            let ret = ark
                .exit
                .call(Ok(code), ThreadsafeFunctionCallMode::NonBlocking);
            match ret {
                Status::Ok => 0,
                _ => -1,
            }
        } else {
            -1
        }
    }
}
