//! Main-thread-only application-control plugin facade.
//!
//! `terminate` maps to the graceful OHOS ability termination
//! (`UIAbilityContext.terminateSelf()`); the requested exit code is advisory
//! only. `restart` maps to the OS relaunch API
//! (`ApplicationContext.restartApp(want)`, API 12+), which tears the process
//! down and relaunches it — third-party apps cannot spawn themselves.

use napi_derive_ohos::napi;
use napi_ohos::{Env, Error, Result};
pub use openharmony_ability::version;
use openharmony_ability::{
    impl_bridge_napi_type, BridgeContextRequirement, BridgePlugin, MainThreadSyncBridge,
    OpenHarmonyApp,
};

/// Minimum API level for `ApplicationContext.restartApp()`.
const MIN_RESTART_API_VERSION: i32 = 12;

pub struct AppControlBridgePlugin;

impl BridgePlugin for AppControlBridgePlugin {
    type Mode = MainThreadSyncBridge;

    const ID: &'static str = "ohos.app-control";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct TerminateRequest {
    pub code: i32,
}

impl_bridge_napi_type!(TerminateRequest, "ohos.app_control.TerminateRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct TerminateResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(TerminateResponse, "ohos.app_control.TerminateResponse");

// ── restart ──────────────────────────────────────────────────────────────────────

/// Request to restart the application via `ApplicationContext.restartApp` (API 12+).
///
/// The relaunch `Want` is derived ArkTS-side from the current UIAbility
/// (`abilityInfo.bundleName` + `abilityInfo.name`), so the request carries no
/// fields.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct RestartRequest {}

impl_bridge_napi_type!(RestartRequest, "ohos.app_control.RestartRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct RestartResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(RestartResponse, "ohos.app_control.RestartResponse");

// ── hide-ability ────────────────────────────────────────────────────────────────

/// Request to hide the application's UIAbility (fire-and-forget).
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct HideAbilityRequest {}

impl_bridge_napi_type!(HideAbilityRequest, "ohos.app_control.HideAbilityRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct HideAbilityResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(HideAbilityResponse, "ohos.app_control.HideAbilityResponse");

// ── show-ability ─────────────────────────────────────────────────────────────────

/// Request to restore a hidden UIAbility to the foreground (fire-and-forget).
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ShowAbilityRequest {}

impl_bridge_napi_type!(ShowAbilityRequest, "ohos.app_control.ShowAbilityRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ShowAbilityResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(ShowAbilityResponse, "ohos.app_control.ShowAbilityResponse");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct SetColorModeRequest {
    /// 0 = Dark, 1 = Light, 2 = NoSet (follow system).
    pub color_mode: i32,
}

impl_bridge_napi_type!(SetColorModeRequest, "ohos.app_control.SetColorModeRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct SetColorModeResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    SetColorModeResponse,
    "ohos.app_control.SetColorModeResponse"
);

// ── start-ui-ability ────────────────────────────────────────────────────────────

/// Request to spawn a new UIAbility instance carrying a pre-allocated window id
/// (multi-UIAbility windows, openspec multi-uiability-windows D1).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct StartUiAbilityRequest {
    /// Pre-allocated window id (`next_window_id()` on the tao side). Travelled
    /// to the new instance via `want.parameters.tauri_window_id`.
    pub window_id: i64,
    /// Window label (tauri window registry key).
    pub label: String,
    /// Initial webview URL; empty string leaves the instance on its default
    /// page (OQ5 — delivered separately by wry's WebviewCreateRequest).
    pub url: String,
    /// Window transparency flag (mirrors `WebviewWindowBuilder` semantics).
    pub transparent: bool,
    /// Optional creation-time window width, physical px (tao#26 review
    /// follow-up F5): applied via `StartOptions.windowWidth` on
    /// `startAbility` (API 11+). `None` keeps the OS default. StartOptions
    /// sizes the window rectangle (frame included) — same contract as the
    /// Float path's `WindowCreateParams`.
    pub width: Option<i32>,
    /// Optional creation-time window height, physical px — see `width`.
    pub height: Option<i32>,
    /// Optional creation-time window left, physical px — applied via
    /// `StartOptions.windowLeft`. `None` keeps the OS default placement.
    pub left: Option<i32>,
    /// Optional creation-time window top, physical px — see `left`.
    pub top: Option<i32>,
}

impl_bridge_napi_type!(
    StartUiAbilityRequest,
    "ohos.app_control.StartUiAbilityRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct StartUiAbilityResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    StartUiAbilityResponse,
    "ohos.app_control.StartUiAbilityResponse"
);

/// Dispatches `startAbility` for a new UIAbility instance (fire-and-forget).
///
/// Worker-thread facade for tao's `Window::new` (multi-UIAbility path, design
/// D1): the window id is allocated synchronously by the caller and registered
/// in the pending-ability registry *before* this call, so the handshake stays
/// event-driven (D7) — no blocking wait for the new instance's
/// `register_ui_ability_stage` (HC-5).
///
/// `accepted` only means the ArkTS handler validated the payload and queued
/// `context.startAbility` via `setTimeout(…, 0)`; the actual spawn result is
/// observable only through the D7 registry (`register_ui_ability_stage` /
/// hilog), not through this response.
///
/// `inner_size` / `position` (physical px tuples) carry the builder's
/// creation-time geometry through to the `startAbility` StartOptions
/// (tao#26 review follow-up F5); `None` leaves the OS default for that
/// axis pair.
///
/// Must be awaited off the N-API main thread (e.g. from tao's
/// `BridgeExecutor` worker) — `call_sync_from_worker` rejects main-thread
/// callers outright to avoid the self-deadlock.
pub async fn start_ui_ability(
    app: &OpenHarmonyApp,
    window_id: i64,
    label: String,
    url: String,
    transparent: bool,
    inner_size: Option<(i32, i32)>,
    position: Option<(i32, i32)>,
) -> Result<()> {
    // Record the label→id pairing so deep-link's per-window resolution can map a
    // calling Window's label back to its instance's want-URI storage (design D9).
    ::openharmony_ability::register_window_label(&label, window_id);
    let (width, height) = match inner_size {
        Some((w, h)) => (Some(w), Some(h)),
        None => (None, None),
    };
    let (left, top) = match position {
        Some((x, y)) => (Some(x), Some(y)),
        None => (None, None),
    };
    let result = match app.bridge() {
        Ok(bridge) => {
            bridge
                .call_sync_from_worker::<AppControlBridgePlugin, StartUiAbilityRequest, StartUiAbilityResponse>(
                    "start-ui-ability",
                    StartUiAbilityRequest {
                        window_id,
                        label,
                        url,
                        transparent,
                        width,
                        height,
                        left,
                        top,
                    },
                )
                .await
        }
        Err(e) => Err(e),
    };
    // Roll the pairing back on every failure path (G15): a label whose start
    // never completed must not keep resolving to a dead id — deep-link's
    // "never spawned → primary (id 0)" contract (D9) would silently break.
    match result {
        Ok(response) if response.accepted => Ok(()),
        Ok(_) => {
            ::openharmony_ability::unregister_window_label(window_id);
            Err(Error::from_reason(
                "App-control plugin rejected start-ui-ability",
            ))
        }
        Err(e) => {
            ::openharmony_ability::unregister_window_label(window_id);
            Err(e)
        }
    }
}

/// A synchronous capability must be invoked in an exported N-API callback that owns `Env`.
pub trait AppControlExt {
    /// Terminates the application gracefully (`UIAbilityContext.terminateSelf()`).
    ///
    /// The `code` is advisory only — OHOS ability termination has no process
    /// exit-code channel; the ArkTS side logs it. Teardown is deferred to the
    /// next event-loop tick so the bridge response unwinds first.
    fn terminate(&self, env: &Env, code: i32) -> Result<()>;
    /// Restarts the application via the OS relaunch API
    /// (`ApplicationContext.restartApp()`, API 12+).
    ///
    /// On lower API levels, returns an error naming the required API level.
    /// The system only honours the request while the app is in the foreground
    /// with focus.
    fn restart(&self, env: &Env) -> Result<()>;
    fn hide_ability(&self, env: &Env) -> Result<()>;
    fn show_ability(&self, env: &Env) -> Result<()>;
}

impl AppControlExt for OpenHarmonyApp {
    fn terminate(&self, env: &Env, code: i32) -> Result<()> {
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<AppControlBridgePlugin, TerminateRequest, TerminateResponse>(
                    "terminate",
                    TerminateRequest { code },
                )?;
            if !response.accepted {
                return Err(Error::from_reason(
                    "App-control plugin rejected termination",
                ));
            }
            Ok(())
        })
    }

    fn restart(&self, env: &Env) -> Result<()> {
        if version::sdk_api_version() < MIN_RESTART_API_VERSION {
            return Err(Error::from_reason(format!(
                "restart requires API level {MIN_RESTART_API_VERSION}+ on OpenHarmony (current: {})",
                version::sdk_api_version()
            )));
        }
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<AppControlBridgePlugin, RestartRequest, RestartResponse>(
                    "restart",
                    RestartRequest {},
                )?;
            if !response.accepted {
                return Err(Error::from_reason("App-control plugin rejected restart"));
            }
            Ok(())
        })
    }

    fn hide_ability(&self, env: &Env) -> Result<()> {
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<AppControlBridgePlugin, HideAbilityRequest, HideAbilityResponse>(
                    "hide-ability",
                    HideAbilityRequest {},
                )?;
            if !response.accepted {
                return Err(Error::from_reason(
                    "App-control plugin rejected hide-ability",
                ));
            }
            Ok(())
        })
    }

    fn show_ability(&self, env: &Env) -> Result<()> {
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<AppControlBridgePlugin, ShowAbilityRequest, ShowAbilityResponse>(
                    "show-ability",
                    ShowAbilityRequest {},
                )?;
            if !response.accepted {
                return Err(Error::from_reason(
                    "App-control plugin rejected show-ability",
                ));
            }
            Ok(())
        })
    }
}

/// Synchronous color-mode control scoped to the active N-API `Env`.
///
/// The `color_mode` integer uses the bridge contract: `0 = Dark`, `1 = Light`,
/// `2 = NoSet` (follow system). The ArkTS side maps this to
/// `ConfigurationConstant.ColorMode` via a switch/default and defers the actual
/// `setColorMode` call with `setTimeout(…, 0)` to avoid re-entrant
/// `onConfigurationUpdate` deadlocks (see ohos-constraints 4.3).
pub trait ColorModeExt {
    fn set_color_mode(&self, env: &Env, color_mode: i32) -> Result<()>;
}

impl ColorModeExt for OpenHarmonyApp {
    fn set_color_mode(&self, env: &Env, color_mode: i32) -> Result<()> {
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<AppControlBridgePlugin, SetColorModeRequest, SetColorModeResponse>(
                    "set-color-mode",
                    SetColorModeRequest { color_mode },
                )?;
            if !response.accepted {
                return Err(Error::from_reason(
                    "App-control plugin rejected color mode change",
                ));
            }
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{
        HideAbilityRequest, HideAbilityResponse, RestartRequest, RestartResponse,
        SetColorModeRequest, SetColorModeResponse, ShowAbilityRequest, ShowAbilityResponse,
        StartUiAbilityRequest, StartUiAbilityResponse, TerminateRequest, TerminateResponse,
    };
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn terminate_uses_a_stable_named_napi_contract() {
        assert_eq!(
            <TerminateRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.TerminateRequest"
        );
        assert_eq!(
            <TerminateResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.TerminateResponse"
        );
        assert_eq!(TerminateRequest { code: -1 }.code, -1);
        assert!(TerminateResponse { accepted: true }.accepted);
    }

    #[test]
    fn restart_uses_a_stable_named_napi_contract() {
        assert_eq!(
            <RestartRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.RestartRequest"
        );
        assert_eq!(
            <RestartResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.RestartResponse"
        );
        assert!(RestartResponse { accepted: true }.accepted);
    }

    #[test]
    fn set_color_mode_uses_a_stable_named_napi_contract() {
        assert_eq!(
            <SetColorModeRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.SetColorModeRequest"
        );
        assert_eq!(
            <SetColorModeResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.SetColorModeResponse"
        );
        assert_eq!(SetColorModeRequest { color_mode: 0 }.color_mode, 0);
        assert!(SetColorModeResponse { accepted: true }.accepted);
    }

    #[test]
    fn hide_ability_uses_a_stable_named_napi_contract() {
        assert_eq!(
            <HideAbilityRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.HideAbilityRequest"
        );
        assert_eq!(
            <HideAbilityResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.HideAbilityResponse"
        );
        assert!(HideAbilityResponse { accepted: true }.accepted);
    }

    #[test]
    fn show_ability_uses_a_stable_named_napi_contract() {
        assert_eq!(
            <ShowAbilityRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.ShowAbilityRequest"
        );
        assert_eq!(
            <ShowAbilityResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.ShowAbilityResponse"
        );
        assert!(ShowAbilityResponse { accepted: true }.accepted);
    }

    #[test]
    fn start_ui_ability_uses_a_stable_named_napi_contract() {
        assert_eq!(
            <StartUiAbilityRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.StartUiAbilityRequest"
        );
        assert_eq!(
            <StartUiAbilityResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.StartUiAbilityResponse"
        );
        // NAPI wire names are camelCase (window_id → windowId); the Rust-side
        // field stays snake_case. Round-trip the payload shape the ArkTS
        // parser expects (integer id, string label/url, boolean transparent,
        // optional physical-px geometry — absent reads as undefined).
        let request = StartUiAbilityRequest {
            window_id: 1,
            label: "uiability-1".into(),
            url: String::new(),
            transparent: false,
            width: Some(700),
            height: Some(500),
            left: Some(90),
            top: Some(70),
        };
        assert_eq!(request.window_id, 1);
        assert_eq!(request.label, "uiability-1");
        assert!(request.url.is_empty());
        assert!(!request.transparent);
        assert_eq!(request.width, Some(700));
        assert_eq!(request.height, Some(500));
        assert_eq!(request.left, Some(90));
        assert_eq!(request.top, Some(70));
        let unset = StartUiAbilityRequest {
            window_id: 2,
            label: "uiability-2".into(),
            url: String::new(),
            transparent: true,
            width: None,
            height: None,
            left: None,
            top: None,
        };
        assert!(unset.width.is_none() && unset.height.is_none());
        assert!(unset.left.is_none() && unset.top.is_none());
        assert!(StartUiAbilityResponse { accepted: true }.accepted);
    }
}
