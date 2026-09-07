// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! Updater functionality for OpenHarmony via AppGallery (bridge plugin).
//!
//! The ArkTS half (`plugins/updater/src/main/ets/UpdaterPlugin.ets`) is an
//! `AsyncPluginBase` with id `ohos.updater` and `requires: ["ability"]`. It
//! wraps `updateManager` from `@kit.AppGalleryKit` and exposes two actions:
//! - `check`              → pure query via `updateManager.checkAppUpdate`; no
//!   dialog. Returns `updateAvailable` plus `currentVersion` / `version` /
//!   `body` / `date`.
//! - `downloadAndInstall` → shows the system AppGallery update dialog, which
//!   drives the entire download + install flow.
//!
//! This replaces the former TSFN transport (`helper/updater.ets` +
//! `get_updater_check_tsfn()` / `get_updater_download_and_install_tsfn()`).
//! Those globals were never initialized after the `#[ability]` derive
//! refactor — `set_helper` is never called, so the TSFN callbacks could not
//! resolve `helper.updaterCheck()` / `updaterDownloadAndInstall()`, and every
//! call failed at runtime with "TSFN not initialized". The bridge plugin model
//! routes through `OpenHarmonyApp::bridge()` → `bridgeInvoke`, which is wired
//! up per Ability session.

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use serde::{Deserialize, Serialize};

use crate::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

// ── Plugin identity ────────────────────────────────────────────────────────

/// Core-privileged OHOS capability (not Tauri-shaped).
///
/// First-class OHOS ability exposed on par with `RuntimeInitArgs.app`.
/// Intentionally NOT facade-ized: the API has no Tauri shape (pure OHOS
/// platform capability). Precedent: `OpenHarmonyApp::updater()`.
pub struct UpdaterBridgePlugin;

impl BridgePlugin for UpdaterBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.updater";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

// ── Request / Response contracts ────────────────────────────────────────────

/// Empty request marker for the `check` action.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct UpdaterCheckRequest {}

impl_bridge_napi_type!(UpdaterCheckRequest, "ohos.updater.CheckRequest");

/// Response carrying the AppGallery update probe result. The `update_available`
/// flag lets the Rust facade decide whether to surface a `CheckResult`.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct UpdaterCheckResponse {
    pub update_available: bool,
    pub current_version: String,
    /// `None` when the device API level is below 20 (`versionName` unavailable).
    pub version: Option<String>,
    pub body: Option<String>,
    pub date: Option<String>,
}

impl_bridge_napi_type!(UpdaterCheckResponse, "ohos.updater.CheckResponse");

/// Empty request marker for the `downloadAndInstall` action.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct UpdaterDownloadAndInstallRequest {}

impl_bridge_napi_type!(
    UpdaterDownloadAndInstallRequest,
    "ohos.updater.DownloadAndInstallRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct UpdaterDownloadAndInstallResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    UpdaterDownloadAndInstallResponse,
    "ohos.updater.DownloadAndInstallResponse"
);

// ── CheckResult (public serde type) ─────────────────────────────────────────

/// Core-privileged OHOS capability (not Tauri-shaped).
///
/// First-class OHOS ability exposed on par with `RuntimeInitArgs.app`.
/// Intentionally NOT facade-ized: the API has no Tauri shape (pure OHOS
/// platform capability). Precedent: `OpenHarmonyApp::updater()`.
///
/// Result from checking for updates via AppGallery.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckResult {
    pub current_version: String,
    /// `None` when the device API level is below 20 (`versionName` unavailable).
    pub version: Option<String>,
    pub body: Option<String>,
    pub date: Option<String>,
}

// ── Updater facade ───────────────────────────────────────────────────────────

/// Core-privileged OHOS capability (not Tauri-shaped).
///
/// First-class OHOS ability exposed on par with `RuntimeInitArgs.app`.
/// Intentionally NOT facade-ized: the API has no Tauri shape (pure OHOS
/// platform capability). Precedent: `OpenHarmonyApp::updater()`.
///
/// Updater handle for checking and installing updates via AppGallery.
/// Holds a [`BridgeRuntime`] clone obtained from [`OpenHarmonyApp::bridge`].
///
/// # Breaking change (2026-08-21)
///
/// `OpenHarmonyApp::updater()` previously returned `Updater` directly (the handle
/// was zero-sized and relied on global TSFNs). Those TSFNs were never wired up
/// after the `#[ability]` derive refactor (`set_helper` is never called), so
/// every call silently failed. The method now returns `Result<Updater>` and the
/// handle resolves the bridge runtime explicitly. Callers must update:
///
/// ```ignore
/// // before
/// let updater = app.updater();
/// // after
/// let updater = app.updater()?;
/// ```
pub struct Updater {
    bridge: BridgeRuntime,
}

impl Updater {
    /// Create a new handle bound to the given app's bridge runtime.
    pub(crate) fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }

    /// Check for app updates via AppGallery. Pure query — no dialog is shown.
    /// Returns `Ok(Some(result))` if an update is available, `Ok(None)` otherwise.
    pub async fn check(&self) -> Result<Option<CheckResult>> {
        let response = self
            .call::<UpdaterCheckRequest, UpdaterCheckResponse>("check", UpdaterCheckRequest {})
            .await?;
        if !response.update_available {
            return Ok(None);
        }
        Ok(Some(CheckResult {
            current_version: response.current_version,
            version: response.version,
            body: response.body,
            date: response.date,
        }))
    }

    /// Show the AppGallery update dialog. Drives the full download+install flow.
    pub async fn download_and_install(&self) -> Result<()> {
        let response = self
            .call::<UpdaterDownloadAndInstallRequest, UpdaterDownloadAndInstallResponse>(
                "downloadAndInstall",
                UpdaterDownloadAndInstallRequest {},
            )
            .await?;
        if response.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "updater downloadAndInstall rejected by plugin",
            ))
        }
    }

    async fn call<Request, Response>(&self, action: &str, request: Request) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.bridge
            .call_async::<UpdaterBridgePlugin, Request, Response>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_result_serde_roundtrip() {
        let result = CheckResult {
            current_version: "1.0.0".into(),
            version: Some("2.0.0".into()),
            body: Some("Bug fixes".into()),
            date: Some("2025-01-15".into()),
        };
        let json = serde_json::to_string(&result).unwrap();
        assert!(json.contains("\"currentVersion\":\"1.0.0\""));
        assert!(json.contains("\"version\":\"2.0.0\""));
        let deserialized: CheckResult = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.current_version, "1.0.0");
        assert_eq!(deserialized.version.as_deref(), Some("2.0.0"));
        assert_eq!(deserialized.body, Some("Bug fixes".into()));
        assert_eq!(deserialized.date, Some("2025-01-15".into()));
    }

    #[test]
    fn check_result_optional_nulls() {
        let json = r#"{"currentVersion":"1.0.0","version":null,"body":null,"date":null}"#;
        let result: CheckResult = serde_json::from_str(json).unwrap();
        assert_eq!(result.current_version, "1.0.0");
        assert_eq!(result.version, None);
        assert_eq!(result.body, None);
        assert_eq!(result.date, None);
    }

    #[test]
    fn check_result_unknown_version_fallback() {
        // Simulates SDK 12 where versionName is not available (ArkTS returns null)
        let result = CheckResult {
            current_version: "1.0.0".into(),
            version: None,
            body: None,
            date: None,
        };
        let json = serde_json::to_value(&result).unwrap();
        assert!(json["version"].is_null());
    }

    #[test]
    fn updater_plugin_targets_ability_context() {
        assert_eq!(UpdaterBridgePlugin::ID, "ohos.updater");
        assert_eq!(
            UpdaterBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }

    #[test]
    fn updater_types_have_stable_named_napi_contracts() {
        assert_eq!(
            <UpdaterCheckRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.updater.CheckRequest"
        );
        assert_eq!(
            <UpdaterCheckResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.updater.CheckResponse"
        );
        assert_eq!(
            <UpdaterDownloadAndInstallRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.updater.DownloadAndInstallRequest"
        );
        assert_eq!(
            <UpdaterDownloadAndInstallResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.updater.DownloadAndInstallResponse"
        );
    }
}
