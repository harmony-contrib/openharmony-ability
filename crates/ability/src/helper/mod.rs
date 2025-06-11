use std::{cell::RefCell, rc::Rc};

use ohos_display_binding::default_display_scaled_density;

mod ark;
mod webview;
mod window_info;

pub use ark::*;
pub use webview::*;

pub(crate) struct Helper {
    #[allow(dead_code)]
    pub(crate) ark: Rc<RefCell<Option<ArkTSHelper<'static>>>>,
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
        Helper {
            ark: Rc::new(RefCell::new(None)),
        }
    }
}

impl Helper {
    pub fn new() -> Self {
        Helper {
            ark: Rc::new(RefCell::new(None)),
        }
    }

    pub fn scale(&self) -> f32 {
        default_display_scaled_density()
    }

    /// exit current app
    pub fn exit(&self, code: i32) -> i32 {
        if let Some(ark) = self.ark.borrow().as_ref() {
            return match ark.exit.call(code) {
                Ok(_) => 0,
                Err(_) => -1,
            };
        }
        -1
    }
}
