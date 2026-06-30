// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! Autostart functionality for OpenHarmony.
//!
//! The ArkTS side (`helper/autostart.ets`) provides:
//! - `autostartEnable()` / `autostartDisable()` — opens system settings page
//! - `autostartIsEnabled()` — queries `autoStartupManager.getAutoStartupStatusForSelf()` (API 21+)
//!
//! The TSFN infrastructure (in `helper/autostart.rs`) bridges ArkTS Promises to Rust Futures.
//!
//! OHOS platform constraints:
//! - Ordinary apps cannot programmatically enable/disable autostart
//! - `enable()` / `disable()` navigate to the system settings page for manual toggle
//! - `isEnabled()` queries the real status via `autoStartupManager` (API 21+)
//! - On API < 21, `isEnabled()` returns `Ok(false)` (forced fallback value)

use std::{cell::Cell, rc::Rc};

use futures_channel::oneshot;
use napi_ohos::{
    bindgen_prelude::{CallbackContext, PromiseRaw, Unknown},
    threadsafe_function::ThreadsafeFunctionCallMode,
    Error, Result, Status, ValueType,
};
use tokio::time::{timeout, Duration};

use crate::helper::{
    get_autostart_disable_tsfn, get_autostart_enable_tsfn, get_autostart_is_enabled_tsfn,
};

/// Autostart manager for OHOS platform.
///
/// Both `enable()` and `disable()` open the **same** system "App launch management"
/// settings page — OHOS does not allow ordinary apps to programmatically toggle
/// autostart. Method names reflect user intent, not guaranteed outcome.
pub struct AutostartManager;

impl AutostartManager {
    /// Navigate to system autostart settings page.
    ///
    /// Both `enable()` and `disable()` open the **same** page —
    /// OHOS does not allow apps to programmatically toggle autostart.
    /// Method names reflect user intent, not guaranteed outcome.
    pub async fn enable(&self) -> Result<()> {
        let tsfn = get_autostart_enable_tsfn()
            .ok_or_else(|| Error::from_reason("autostart enable TSFN not initialized"))?;

        let (tx, rx) = oneshot::channel();
        let tx_cell = Rc::new(Cell::new(Some(tx)));

        let status = tsfn.call_with_return_value(
            (),
            ThreadsafeFunctionCallMode::NonBlocking,
            move |result, _env| {
                match result {
                    Ok(value) => handle_void_promise(value, tx_cell.clone()),
                    Err(err) => { send_once(&tx_cell, Err(err)); Ok(()) }
                }
            },
        );

        if status != Status::Ok {
            return Err(Error::from_reason(format!(
                "call autostartEnable TSFN failed: {:?}",
                status
            )));
        }

        // Timeout: 10s for enable (user may take time in settings page)
        timeout(Duration::from_secs(10), rx)
            .await
            .map_err(|_| Error::from_reason("autostart enable timed out"))?
            .map_err(|_| Error::from_reason("autostart enable receiver dropped"))?
    }

    /// Navigate to system autostart settings page.
    ///
    /// Both `enable()` and `disable()` open the **same** page —
    /// OHOS does not allow apps to programmatically toggle autostart.
    /// Method names reflect user intent, not guaranteed outcome.
    pub async fn disable(&self) -> Result<()> {
        let tsfn = get_autostart_disable_tsfn()
            .ok_or_else(|| Error::from_reason("autostart disable TSFN not initialized"))?;

        let (tx, rx) = oneshot::channel();
        let tx_cell = Rc::new(Cell::new(Some(tx)));

        let status = tsfn.call_with_return_value(
            (),
            ThreadsafeFunctionCallMode::NonBlocking,
            move |result, _env| {
                match result {
                    Ok(value) => handle_void_promise(value, tx_cell.clone()),
                    Err(err) => { send_once(&tx_cell, Err(err)); Ok(()) }
                }
            },
        );

        if status != Status::Ok {
            return Err(Error::from_reason(format!(
                "call autostartDisable TSFN failed: {:?}",
                status
            )));
        }

        // Timeout: 10s for disable (same as enable)
        timeout(Duration::from_secs(10), rx)
            .await
            .map_err(|_| Error::from_reason("autostart disable timed out"))?
            .map_err(|_| Error::from_reason("autostart disable receiver dropped"))?
    }

    /// Query whether autostart is enabled for this app.
    ///
    /// On API < 21, returns `Ok(false)` without TSFN call (forced fallback value).
    /// On API 21+, queries `autoStartupManager.getAutoStartupStatusForSelf()` via TSFN.
    pub async fn is_enabled(&self) -> Result<bool> {
        // Version guard: autoStartupManager requires API 21+
        if crate::version::sdk_api_version() < 21 {
            return Ok(false);
        }

        let tsfn = get_autostart_is_enabled_tsfn()
            .ok_or_else(|| Error::from_reason("autostart isEnabled TSFN not initialized"))?;

        let (tx, rx) = oneshot::channel();
        let tx_cell = Rc::new(Cell::new(Some(tx)));

        let status = tsfn.call_with_return_value(
            (),
            ThreadsafeFunctionCallMode::NonBlocking,
            move |result, _env| {
                match result {
                    Ok(value) => handle_bool_promise(value, tx_cell.clone()),
                    Err(err) => { send_once(&tx_cell, Err(err)); Ok(()) }
                }
            },
        );

        if status != Status::Ok {
            return Err(Error::from_reason(format!(
                "call autostartIsEnabled TSFN failed: {:?}",
                status
            )));
        }

        // Timeout: 5s for isEnabled (pure query, should be fast)
        timeout(Duration::from_secs(5), rx)
            .await
            .map_err(|_| Error::from_reason("autostart isEnabled timed out"))?
            .map_err(|_| Error::from_reason("autostart isEnabled receiver dropped"))?
    }
}

// ── Helpers ──────────────────────────────────────────────────────────

fn send_once<T>(cell: &Rc<Cell<Option<oneshot::Sender<T>>>>, value: T) {
    if let Some(sender) = cell.replace(None) {
        let _ = sender.send(value);
    }
}

fn handle_void_promise(
    value: Unknown<'static>,
    tx: Rc<Cell<Option<oneshot::Sender<Result<()>>>>>,
) -> Result<()> {
    // Validate type before unsafe cast (prevent UB on non-Promise values)
    if value.get_type()? != ValueType::Object {
        send_once(&tx, Err(Error::from_reason("expected Promise from ArkTS")));
        return Ok(());
    }

    let promise: PromiseRaw<'static, ()> = unsafe { value.cast()? };

    let tx_catch = tx.clone();
    promise
        .then(move |_ctx: CallbackContext<()>| {
            send_once(&tx, Ok(()));
            Ok(())
        })?
        .catch(move |ctx: CallbackContext<Unknown>| {
            send_once(&tx_catch, Err(ctx.value.into()));
            Ok(())
        })?;

    Ok(())
}

fn handle_bool_promise(
    value: Unknown<'static>,
    tx: Rc<Cell<Option<oneshot::Sender<Result<bool>>>>>,
) -> Result<()> {
    // Validate type before unsafe cast (prevent UB on non-Promise values)
    if value.get_type()? != ValueType::Object {
        send_once(&tx, Err(Error::from_reason("expected Promise from ArkTS")));
        return Ok(());
    }

    let promise: PromiseRaw<'static, bool> = unsafe { value.cast()? };

    let tx_catch = tx.clone();
    promise
        .then(move |ctx: CallbackContext<bool>| {
            send_once(&tx, Ok(ctx.value));
            Ok(())
        })?
        .catch(move |ctx: CallbackContext<Unknown>| {
            send_once(&tx_catch, Err(ctx.value.into()));
            Ok(())
        })?;

    Ok(())
}
