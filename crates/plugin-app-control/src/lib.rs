//! Main-thread-only application-control plugin facade.

use napi_derive_ohos::napi;
use napi_ohos::{Env, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, BridgeContextRequirement, BridgePlugin, MainThreadSyncBridge,
    OpenHarmonyApp,
};

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

/// A synchronous capability must be invoked in an exported N-API callback that owns `Env`.
pub trait AppControlExt {
    fn terminate(&self, env: &Env, code: i32) -> Result<()>;
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
        HideAbilityRequest, HideAbilityResponse, SetColorModeRequest, SetColorModeResponse,
        ShowAbilityRequest, ShowAbilityResponse, TerminateRequest, TerminateResponse,
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
}
