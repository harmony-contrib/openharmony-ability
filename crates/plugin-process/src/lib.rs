// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! Process control for OpenHarmony (bridge plugin).
//!
//! The ArkTS half (`plugins/process/src/main/ets/ProcessPlugin.ets`) is an
//! `AsyncPluginBase` with id `ohos.process` and `requires: []`. It exposes:
//! - `restart` → `appRecovery.enableAppRecovery(...)` + `appRecovery.restartApp()`.
//!   The process is hard-killed by the system; `onDestroy` is NOT triggered.
//!
//! This restores the restart transport that was lost during decoupling: the
//! former TSFN path (`helper/restart.ets`) depended on `set_helper`, which is
//! never called after the `#[ability]` derive refactor, so it could never
//! dispatch. The bridge plugin model routes through
//! `OpenHarmonyApp::bridge()` → `bridgeInvoke`, which is wired up per Ability
//! session.

use napi_derive_ohos::napi;
use napi_ohos::Result;

use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement, BridgePlugin,
    BridgeRuntime, OpenHarmonyApp,
};

// ── Plugin identity ────────────────────────────────────────────────────────

/// Pure OHOS platform capability with no Tauri shape, exposed as a dedicated
/// plugin crate. Pairs with the ArkTS HAR `plugins/process`
/// (`@ohos-rs/ability-plugin-process`).
///
/// Consumed by the `tauri-plugin-process` crate, which registers this plugin
/// in its OHOS `setup` so the `ohos.process` declaration flows to ArkTS.
pub struct ProcessBridgePlugin;

impl BridgePlugin for ProcessBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.process";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] = &[];
}

// ── Request / Response contracts ────────────────────────────────────────────

/// Empty request marker for the `restart` action.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct RestartRequest {}

impl_bridge_napi_type!(RestartRequest, "ohos.process.RestartRequest");

/// Result of dispatching `appRecovery.restartApp()`.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct RestartResponse {
    /// 0 on success, negative on failure (mirrors the former TSFN contract).
    pub code: i32,
}

impl_bridge_napi_type!(RestartResponse, "ohos.process.RestartResponse");

// ── Process facade ──────────────────────────────────────────────────────────

/// Pure OHOS platform capability with no Tauri shape, exposed by this plugin
/// crate. Pairs with the ArkTS HAR `plugins/process`.
///
/// Process handle for dispatching app-level process control via the bridge.
/// Holds a [`BridgeRuntime`] clone obtained from [`OpenHarmonyApp::bridge`].
///
/// The handle exists so callers can drop the `tauri::ohos::APP` mutex guard
/// before `.await`ing — holding a `MutexGuard` across an await point would
/// make the command future non-`Send`.
pub struct Process {
    bridge: BridgeRuntime,
}

impl Process {
    /// Create a new handle bound to the given app's bridge runtime.
    ///
    /// Returns an error if the bridge session is not yet active (call during an
    /// active `NativeAbility` session).
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }

    /// Dispatch `appRecovery.restartApp()` on the ArkTS main thread.
    ///
    /// Returns `Ok(0)` when the restart was dispatched. The process is then
    /// hard-killed by the system (no `onDestroy`); callers should block (or
    /// idle) and let the runtime terminate them, matching the non-OHOS
    /// restart path.
    pub async fn restart(&self) -> Result<i32> {
        let response = self
            .bridge
            .call_async::<ProcessBridgePlugin, RestartRequest, RestartResponse>(
                "restart",
                RestartRequest {},
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.code)
    }
}

pub trait ProcessExt {
    /// App process control handle. Requires an active `NativeAbility` session.
    fn process(&self) -> Result<Process>;
}

impl ProcessExt for OpenHarmonyApp {
    fn process(&self) -> Result<Process> {
        Process::new(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn process_plugin_requires_no_contexts() {
        assert_eq!(ProcessBridgePlugin::ID, "ohos.process");
        assert!(ProcessBridgePlugin::REQUIRED_CONTEXTS.is_empty());
    }

    #[test]
    fn process_types_have_stable_named_napi_contracts() {
        assert_eq!(
            <RestartRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.process.RestartRequest"
        );
        assert_eq!(
            <RestartResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.process.RestartResponse"
        );
    }
}
