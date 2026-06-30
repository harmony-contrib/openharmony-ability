// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! TSFN infrastructure for updater operations.
//!
//! Three TSFNs are created during ability init (in `render/xcomponent.rs`):
//! - `UPDATER_CHECK_TSFN`: calls `helper.updaterCheck()` → `Promise<Object | null>`
//! - `UPDATER_SHOW_DIALOG_TSFN`: calls `helper.updaterShowDialog()` → `Promise<number>`
//! - `UPDATER_DOWNLOAD_AND_INSTALL_TSFN`: calls `helper.updaterDownloadAndInstall()` → `Promise<void>`

use std::sync::{Arc, LazyLock, RwLock};

use napi_ohos::{
    bindgen_prelude::{Function, JsObjectValue, Unknown},
    threadsafe_function::ThreadsafeFunction,
    Env, Error, Result, Status,
};

use crate::get_main_thread_env;

// ─── updaterCheck TSFN ─────────────────────────────────────────────────────

type UpdaterCheckCall<'a> = Function<'a, (), Unknown<'a>>;

pub type UpdaterCheckTsfn = ThreadsafeFunction<(), Unknown<'static>, (), Status, false>;

type UpdaterCheckTsfnStore = LazyLock<RwLock<Option<Arc<UpdaterCheckTsfn>>>>;

pub(crate) static UPDATER_CHECK_TSFN: UpdaterCheckTsfnStore =
    LazyLock::new(|| RwLock::new(None));

/// Create the TSFN that calls `helper.updaterCheck()`.
/// Must be called after `set_main_thread_env`.
pub fn create_updater_check_tsfn(env: &Env) -> Result<Arc<UpdaterCheckTsfn>> {
    let callback: Function<'_, (), Unknown<'_>> =
        env.create_function_from_closure("updater_check_callback", move |_ctx| {
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref =
                        helper_obj.get_named_property::<UpdaterCheckCall<'_>>("updaterCheck")?;
                    return fn_ref.call(());
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.updaterCheck from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*UPDATER_CHECK_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write UPDATER_CHECK_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    Ok(tsfn_arc)
}

pub fn get_updater_check_tsfn() -> Option<Arc<UpdaterCheckTsfn>> {
    (*UPDATER_CHECK_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}

// ─── updaterShowDialog TSFN ────────────────────────────────────────────────

type UpdaterShowDialogCall<'a> = Function<'a, (), Unknown<'a>>;

pub type UpdaterShowDialogTsfn = ThreadsafeFunction<(), Unknown<'static>, (), Status, false>;

type UpdaterShowDialogTsfnStore = LazyLock<RwLock<Option<Arc<UpdaterShowDialogTsfn>>>>;

pub(crate) static UPDATER_SHOW_DIALOG_TSFN: UpdaterShowDialogTsfnStore =
    LazyLock::new(|| RwLock::new(None));

pub fn create_updater_show_dialog_tsfn(env: &Env) -> Result<Arc<UpdaterShowDialogTsfn>> {
    let callback: Function<'_, (), Unknown<'_>> =
        env.create_function_from_closure("updater_show_dialog_callback", move |_ctx| {
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref = helper_obj
                        .get_named_property::<UpdaterShowDialogCall<'_>>("updaterShowDialog")?;
                    return fn_ref.call(());
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.updaterShowDialog from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*UPDATER_SHOW_DIALOG_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write UPDATER_SHOW_DIALOG_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    Ok(tsfn_arc)
}

pub fn get_updater_show_dialog_tsfn() -> Option<Arc<UpdaterShowDialogTsfn>> {
    (*UPDATER_SHOW_DIALOG_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}

// ─── updaterDownloadAndInstall TSFN ────────────────────────────────────────

type UpdaterDownloadAndInstallCall<'a> = Function<'a, (), Unknown<'a>>;

pub type UpdaterDownloadAndInstallTsfn =
    ThreadsafeFunction<(), Unknown<'static>, (), Status, false>;

type UpdaterDownloadAndInstallTsfnStore =
    LazyLock<RwLock<Option<Arc<UpdaterDownloadAndInstallTsfn>>>>;

pub(crate) static UPDATER_DOWNLOAD_AND_INSTALL_TSFN: UpdaterDownloadAndInstallTsfnStore =
    LazyLock::new(|| RwLock::new(None));

pub fn create_updater_download_and_install_tsfn(
    env: &Env,
) -> Result<Arc<UpdaterDownloadAndInstallTsfn>> {
    let callback: Function<'_, (), Unknown<'_>> = env
        .create_function_from_closure("updater_download_and_install_callback", move |_ctx| {
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let fn_ref = helper_obj.get_named_property::<UpdaterDownloadAndInstallCall<'_>>(
                        "updaterDownloadAndInstall",
                    )?;
                    return fn_ref.call(());
                }
            }
            Err(Error::from_reason(
                "Failed to call helper.updaterDownloadAndInstall from main thread",
            ))
        })?;

    let tsfn = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);
    {
        let mut guard = (*UPDATER_DOWNLOAD_AND_INSTALL_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write UPDATER_DOWNLOAD_AND_INSTALL_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }
    Ok(tsfn_arc)
}

pub fn get_updater_download_and_install_tsfn() -> Option<Arc<UpdaterDownloadAndInstallTsfn>> {
    (*UPDATER_DOWNLOAD_AND_INSTALL_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}
