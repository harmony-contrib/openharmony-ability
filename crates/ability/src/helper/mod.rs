use std::{cell::RefCell, rc::Rc};

use napi_ohos::{bindgen_prelude::ObjectRef, Env};

mod permission;
#[cfg(feature = "webview")]
mod webview;
mod window_info;

pub use permission::*;
#[cfg(feature = "webview")]
pub use webview::*;

thread_local! {
    static HELPER: Rc<RefCell<Option<ObjectRef>>> = Rc::new(RefCell::new(None));

    static MAIN_THREAD_ENV: Rc<RefCell<Option<Env>>> = Rc::new(RefCell::new(None));

    // Store the back press interceptor callback for page-level access
    static BACK_PRESS_INTERCEPTOR: Rc<RefCell<Option<Box<dyn FnMut() -> bool + Send + Sync>>>> =
        Rc::new(RefCell::new(None));
}

/// Set the back press interceptor callback
pub fn set_back_press_interceptor(interceptor: Box<dyn FnMut() -> bool + Send + Sync>) {
    BACK_PRESS_INTERCEPTOR.with(|h| {
        *h.borrow_mut() = Some(interceptor);
    });
}

/// Get the back press interceptor result
/// Returns true to intercept back press, false to pass through
pub fn get_back_press_interceptor() -> bool {
    BACK_PRESS_INTERCEPTOR.with(|h| h.borrow_mut().as_mut().map(|f| f()).unwrap_or(true))
}

/// 设置 HELPER 的值
pub fn set_helper(helper: ObjectRef) {
    HELPER.with(|h| {
        *h.borrow_mut() = Some(helper);
    });
}

/// # Safety
pub unsafe fn get_helper() -> Rc<RefCell<Option<ObjectRef>>> {
    HELPER.with(Rc::clone)
}

pub fn set_main_thread_env(env: Env) {
    MAIN_THREAD_ENV.with(|e| {
        *e.borrow_mut() = Some(env);
    });
}

pub fn get_main_thread_env() -> Rc<RefCell<Option<Env>>> {
    MAIN_THREAD_ENV.with(Rc::clone)
}
