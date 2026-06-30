// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! TSFN infrastructure for autostart operations.
//!
//! Three TSFNs are created during ability init (in `render/xcomponent.rs`):
//! - `AUTOSTART_ENABLE_TSFN`: calls `helper.autostartEnable()` → `Promise<void>`
//! - `AUTOSTART_DISABLE_TSFN`: calls `helper.autostartDisable()` → `Promise<void>`
//! - `AUTOSTART_IS_ENABLED_TSFN`: calls `helper.autostartIsEnabled()` → `Promise<boolean>`

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, RwLock};

use napi_ohos::{
    bindgen_prelude::{Function, JsObjectValue, Unknown},
    threadsafe_function::ThreadsafeFunction,
    Env, Error, Result, Status,
};

use crate::get_main_thread_env;

// ─── autostartEnable TSFN ──────────────────────────────────────────────────

type AutostartEnableCall<'a> = Function<'a, (), Unknown<'a>>;

pub type AutostartEnableTsfn = ThreadsafeFunction<(), Unknown<'static>, (), Status, false>;

type AutostartEnableTsfnStore = LazyLock<RwLock<Option<Arc<AutostartEnableTsfn>>>>;

pub(crate) static AUTOSTART_ENABLE_TSFN: AutostartEnableTsfnStore =
    LazyLock::new(|| RwLock::new(None));

static AUTOSTART_ENABLE_INITIALIZED: AtomicBool = AtomicBool::new(false);

/// Create the TSFN that calls `helper.autostartEnable()`.
/// Must be called after `set_main_thread_env`.
pub fn create_autostart_enable_tsfn(env: &Env) -> Result<Arc<AutostartEnableTsfn>> {
    if AUTOSTART_ENABLE_INITIALIZED.load(Ordering::Acquire) {
        return get_autostart_enable_tsfn()
            .ok_or_else(|| Error::from_reason("AUTOSTART_ENABLE_TSFN flag set but TSFN is None"));
    }
    let callback: Function<'_, (), Unknown<'_>> =
        env.create_function_from_closure("autostart_enable_callback", move |_ctx| {
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref =
                        helper_obj.get_named_property::<AutostartEnableCall<'_>>("autostartEnable")?;
                    return fn_ref.call(());
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.autostartEnable from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*AUTOSTART_ENABLE_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write AUTOSTART_ENABLE_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    AUTOSTART_ENABLE_INITIALIZED.store(true, Ordering::Release);
    Ok(tsfn_arc)
}

pub fn get_autostart_enable_tsfn() -> Option<Arc<AutostartEnableTsfn>> {
    (*AUTOSTART_ENABLE_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}

// ─── autostartDisable TSFN ─────────────────────────────────────────────────

type AutostartDisableCall<'a> = Function<'a, (), Unknown<'a>>;

pub type AutostartDisableTsfn = ThreadsafeFunction<(), Unknown<'static>, (), Status, false>;

type AutostartDisableTsfnStore = LazyLock<RwLock<Option<Arc<AutostartDisableTsfn>>>>;

pub(crate) static AUTOSTART_DISABLE_TSFN: AutostartDisableTsfnStore =
    LazyLock::new(|| RwLock::new(None));

static AUTOSTART_DISABLE_INITIALIZED: AtomicBool = AtomicBool::new(false);

pub fn create_autostart_disable_tsfn(env: &Env) -> Result<Arc<AutostartDisableTsfn>> {
    if AUTOSTART_DISABLE_INITIALIZED.load(Ordering::Acquire) {
        return get_autostart_disable_tsfn()
            .ok_or_else(|| Error::from_reason("AUTOSTART_DISABLE_TSFN flag set but TSFN is None"));
    }
    let callback: Function<'_, (), Unknown<'_>> =
        env.create_function_from_closure("autostart_disable_callback", move |_ctx| {
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref = helper_obj
                        .get_named_property::<AutostartDisableCall<'_>>("autostartDisable")?;
                    return fn_ref.call(());
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.autostartDisable from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*AUTOSTART_DISABLE_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write AUTOSTART_DISABLE_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    AUTOSTART_DISABLE_INITIALIZED.store(true, Ordering::Release);
    Ok(tsfn_arc)
}

pub fn get_autostart_disable_tsfn() -> Option<Arc<AutostartDisableTsfn>> {
    (*AUTOSTART_DISABLE_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}

// ─── autostartIsEnabled TSFN ───────────────────────────────────────────────

type AutostartIsEnabledCall<'a> = Function<'a, (), Unknown<'a>>;

pub type AutostartIsEnabledTsfn = ThreadsafeFunction<(), Unknown<'static>, (), Status, false>;

type AutostartIsEnabledTsfnStore = LazyLock<RwLock<Option<Arc<AutostartIsEnabledTsfn>>>>;

pub(crate) static AUTOSTART_IS_ENABLED_TSFN: AutostartIsEnabledTsfnStore =
    LazyLock::new(|| RwLock::new(None));

static AUTOSTART_IS_ENABLED_INITIALIZED: AtomicBool = AtomicBool::new(false);

pub fn create_autostart_is_enabled_tsfn(env: &Env) -> Result<Arc<AutostartIsEnabledTsfn>> {
    if AUTOSTART_IS_ENABLED_INITIALIZED.load(Ordering::Acquire) {
        return get_autostart_is_enabled_tsfn()
            .ok_or_else(|| Error::from_reason("AUTOSTART_IS_ENABLED_TSFN flag set but TSFN is None"));
    }
    let callback: Function<'_, (), Unknown<'_>> =
        env.create_function_from_closure("autostart_is_enabled_callback", move |_ctx| {
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref = helper_obj
                        .get_named_property::<AutostartIsEnabledCall<'_>>("autostartIsEnabled")?;
                    return fn_ref.call(());
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.autostartIsEnabled from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*AUTOSTART_IS_ENABLED_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write AUTOSTART_IS_ENABLED_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    AUTOSTART_IS_ENABLED_INITIALIZED.store(true, Ordering::Release);
    Ok(tsfn_arc)
}

pub fn get_autostart_is_enabled_tsfn() -> Option<Arc<AutostartIsEnabledTsfn>> {
    (*AUTOSTART_IS_ENABLED_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}
