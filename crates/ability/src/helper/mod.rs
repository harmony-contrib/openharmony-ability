use std::{cell::RefCell, rc::Rc};

use napi_ohos::{bindgen_prelude::ObjectRef, Env};

#[cfg(feature = "webview")]
mod webview;
mod window_info;

#[cfg(feature = "webview")]
pub use webview::*;

thread_local! {
    static HELPER: Rc<RefCell<Option<ObjectRef>>> = Rc::new(RefCell::new(None));

    static MAIN_THREAD_ENV: Rc<RefCell<Option<Env>>> = Rc::new(RefCell::new(None));
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
