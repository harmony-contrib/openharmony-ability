use std::{cell::RefCell, rc::Rc};

use napi_ohos::Env;

thread_local! {
    static MAIN_THREAD_ENV: Rc<RefCell<Option<Env>>> = Rc::new(RefCell::new(None));
}

pub fn set_main_thread_env(env: Env) {
    MAIN_THREAD_ENV.with(|rc| {
        *rc.borrow_mut() = Some(env);
    });
}

/// Get a handle to the main thread env.
/// Only returns Some when called from the main thread where set_main_thread_env was called.
///
/// `#[doc(hidden)]` (issue #87 major-10): this exposes raw NAPI machinery that
/// upper layers (tao/tauri) currently need for TSFN-adjacent calls, but it is
/// not part of the supported API surface — do not build new features on it.
#[doc(hidden)]
pub fn get_main_thread_env() -> Rc<RefCell<Option<Env>>> {
    MAIN_THREAD_ENV.with(Rc::clone)
}
