// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! TSFN for the `restart` helper.
//!
//! Created during ability init (in `render/xcomponent.rs`).
//! Allows calling `helper.restart()` from any thread — the TSFN dispatches
//! the call to the main thread where the NAPI env is available.

use std::sync::{Arc, LazyLock, RwLock};

use napi_ohos::{
    bindgen_prelude::{Function, JsObjectValue, Unknown},
    threadsafe_function::ThreadsafeFunction,
    Env, Error, Result, Status,
};

use crate::get_main_thread_env;

type RestartCall<'a> = Function<'a, (), Unknown<'a>>;

pub type RestartTsfn = ThreadsafeFunction<(), Unknown<'static>, (), Status, false>;

type RestartTsfnStore = LazyLock<RwLock<Option<Arc<RestartTsfn>>>>;

pub(crate) static RESTART_TSFN: RestartTsfnStore = LazyLock::new(|| RwLock::new(None));

/// Create the TSFN that calls `helper.restart()`.
/// Must be called after `set_main_thread_env`.
pub fn create_restart_tsfn(env: &Env) -> Result<Arc<RestartTsfn>> {
    let callback: Function<'_, (), Unknown<'_>> =
        env.create_function_from_closure("restart_callback", move |_ctx| {
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref =
                        helper_obj.get_named_property::<RestartCall<'_>>("restart")?;
                    return fn_ref.call(());
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.restart from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*RESTART_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write RESTART_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    Ok(tsfn_arc)
}

pub fn get_restart_tsfn() -> Option<Arc<RestartTsfn>> {
    (*RESTART_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}
