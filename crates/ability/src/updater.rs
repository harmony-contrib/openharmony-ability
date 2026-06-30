// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! Updater functionality for OpenHarmony via AppGallery.
//!
//! The ArkTS side (`helper/updater.ets`) provides async operations backed by
//! `updateManager` from `@kit.AppGalleryKit`. The TSFN infrastructure (in
//! `helper/updater.rs`) bridges ArkTS Promises to Rust Futures.

use std::{cell::Cell, rc::Rc};

use futures_channel::oneshot;
use napi_ohos::{
    bindgen_prelude::{CallbackContext, JsObjectValue, Object, PromiseRaw, Unknown},
    threadsafe_function::ThreadsafeFunctionCallMode,
    Error, Result, Status,
};
use serde::{Deserialize, Serialize};

use crate::helper::{get_updater_check_tsfn, get_updater_download_and_install_tsfn};

/// Result from checking for updates via AppGallery.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckResult {
    pub current_version: String,
    pub version: String,
    pub body: Option<String>,
    pub date: Option<String>,
}

/// Updater handle for checking and installing updates via AppGallery.
///
/// Obtain via `OpenHarmonyApp::updater()`.
pub struct Updater;

impl Updater {
    /// Check for app updates via AppGallery. Pure query — no dialog is shown.
    /// Returns `Ok(Some(result))` if an update is available, `Ok(None)` otherwise.
    pub async fn check(&self) -> Result<Option<CheckResult>> {
        let tsfn = get_updater_check_tsfn()
            .ok_or_else(|| Error::from_reason("updater check TSFN not initialized"))?;

        let (tx, rx) = oneshot::channel();
        let tx_cell = Rc::new(Cell::new(Some(tx)));

        let status = tsfn.call_with_return_value(
            (),
            ThreadsafeFunctionCallMode::NonBlocking,
            move |result, _env| {
                match result {
                    Ok(value) => {
                        handle_check_promise(value, tx_cell.clone());
                    }
                    Err(err) => send_once(&tx_cell, Err(err)),
                }
                Ok(())
            },
        );

        if status != Status::Ok {
            return Err(Error::from_reason(format!(
                "call updaterCheck TSFN failed: {:?}",
                status
            )));
        }

        rx.await
            .map_err(|_| Error::from_reason("updater check receiver dropped"))?
    }

    /// Show the AppGallery update dialog. Drives the full download+install flow.
    pub async fn download_and_install(&self) -> Result<()> {
        let tsfn = get_updater_download_and_install_tsfn()
            .ok_or_else(|| Error::from_reason("updater download_and_install TSFN not initialized"))?;

        let (tx, rx) = oneshot::channel();
        let tx_cell = Rc::new(Cell::new(Some(tx)));

        let status = tsfn.call_with_return_value(
            (),
            ThreadsafeFunctionCallMode::NonBlocking,
            move |result, _env| {
                match result {
                    Ok(value) => {
                        handle_void_promise(value, tx_cell.clone());
                    }
                    Err(err) => send_once(&tx_cell, Err(err)),
                }
                Ok(())
            },
        );

        if status != Status::Ok {
            return Err(Error::from_reason(format!(
                "call updaterDownloadAndInstall TSFN failed: {:?}",
                status
            )));
        }

        rx.await
            .map_err(|_| Error::from_reason("updater download_and_install receiver dropped"))?
    }
}

// ── Helpers ──────────────────────────────────────────────────────────

/// Send a value through a oneshot sender that is wrapped in `Rc<Cell<Option>>`.
/// Only the first call actually sends; subsequent calls are no-ops.
fn send_once<T>(cell: &Rc<Cell<Option<oneshot::Sender<T>>>>, value: T) {
    if let Some(sender) = cell.replace(None) {
        let _ = sender.send(value);
    }
}

/// Attach `.then`/`.catch` to the ArkTS `updaterCheck` Promise.
/// Extracts CheckResult fields on the JS thread (NAPI values cannot cross threads).
fn handle_check_promise(
    value: Unknown<'static>,
    tx: Rc<Cell<Option<oneshot::Sender<Result<Option<CheckResult>>>>>>,
) {
    let promise = unsafe { value.cast::<PromiseRaw<'static, Object<'static>>>() };
    let promise = match promise {
        Ok(p) => p,
        Err(e) => {
            send_once(&tx, Err(e));
            return;
        }
    };

    let tx_then = tx.clone();
    let _ = promise
        .then(move |ctx: CallbackContext<Object<'static>>| {
            let result = parse_check_result(&ctx.value);
            send_once(&tx_then, result);
            Ok(())
        })
        .and_then(|p| {
            p.catch(move |ctx: CallbackContext<Unknown>| {
                send_once(&tx, Err(ctx.value.into()));
                Ok(())
            })
        });
}

/// Attach `.then`/`.catch` to a `Promise<void>`.
fn handle_void_promise(
    value: Unknown<'static>,
    tx: Rc<Cell<Option<oneshot::Sender<Result<()>>>>>,
) {
    let promise = unsafe { value.cast::<PromiseRaw<'static, ()>>() };
    let promise = match promise {
        Ok(p) => p,
        Err(e) => {
            send_once(&tx, Err(e));
            return;
        }
    };

    let tx_then = tx.clone();
    let _ = promise
        .then(move |_ctx: CallbackContext<()>| {
            send_once(&tx_then, Ok(()));
            Ok(())
        })
        .and_then(|p| {
            p.catch(move |ctx: CallbackContext<Unknown>| {
                send_once(&tx, Err(ctx.value.into()));
                Ok(())
            })
        });
}

/// Extract CheckResult fields from a JS Object.
/// Must run on the JS main thread (NAPI values are thread-bound).
fn parse_check_result(obj: &Object<'static>) -> Result<Option<CheckResult>> {
    let update_available = obj.get_named_property::<bool>("updateAvailable").unwrap_or(false);
    if !update_available {
        return Ok(None);
    }

    Ok(Some(CheckResult {
        current_version: obj
            .get_named_property::<String>("currentVersion")
            .unwrap_or_else(|_| "unknown".to_string()),
        version: obj
            .get_named_property::<String>("version")
            .unwrap_or_else(|_| "unknown".to_string()),
        body: obj.get("body").ok().flatten(),
        date: obj.get("date").ok().flatten(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_result_serde_roundtrip() {
        let result = CheckResult {
            current_version: "1.0.0".into(),
            version: "2.0.0".into(),
            body: Some("Bug fixes".into()),
            date: Some("2025-01-15".into()),
        };
        let json = serde_json::to_string(&result).unwrap();
        assert!(json.contains("\"currentVersion\":\"1.0.0\""));
        assert!(json.contains("\"version\":\"2.0.0\""));
        let deserialized: CheckResult = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.current_version, "1.0.0");
        assert_eq!(deserialized.version, "2.0.0");
        assert_eq!(deserialized.body, Some("Bug fixes".into()));
        assert_eq!(deserialized.date, Some("2025-01-15".into()));
    }

    #[test]
    fn check_result_optional_nulls() {
        let json = r#"{"currentVersion":"1.0.0","version":"unknown","body":null,"date":null}"#;
        let result: CheckResult = serde_json::from_str(json).unwrap();
        assert_eq!(result.current_version, "1.0.0");
        assert_eq!(result.version, "unknown");
        assert_eq!(result.body, None);
        assert_eq!(result.date, None);
    }

    #[test]
    fn check_result_unknown_version_fallback() {
        // Simulates SDK 12 where versionName is not available
        let result = CheckResult {
            current_version: "1.0.0".into(),
            version: "unknown".into(),
            body: None,
            date: None,
        };
        let json = serde_json::to_value(&result).unwrap();
        assert_eq!(json["version"], "unknown");
    }
}
