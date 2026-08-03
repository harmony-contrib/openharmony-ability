//! Main-thread-only application-control plugin facade.
//!
//! Capabilities (all synchronous, ability context): `terminate`, `restart` (hard process
//! restart via `appRecovery.restartApp()`), `set-color-mode` (dark/light/system theme).

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
    const VERSION: u32 = 1;
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

/// Marker retained for API symmetry; all actions are synchronous.
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

#[napi(object)]
#[derive(Clone, Debug)]
pub struct RestartRequest {
    pub requested: bool,
}

impl_bridge_napi_type!(RestartRequest, "ohos.app_control.RestartRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct RestartResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(RestartResponse, "ohos.app_control.RestartResponse");

impl RestartResponse {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "App-control plugin rejected the restart request",
            ))
        }
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ColorModeRequest {
    /// 0 = dark, 1 = light, 2 = follow system (`ConfigurationConstant.ColorMode`).
    pub mode: i32,
}

impl_bridge_napi_type!(ColorModeRequest, "ohos.app_control.ColorModeRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ColorModeResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(ColorModeResponse, "ohos.app_control.ColorModeResponse");

impl ColorModeResponse {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "App-control plugin rejected the color mode change",
            ))
        }
    }
}

/// A synchronous capability must be invoked in an exported N-API callback that owns `Env`.
pub trait AppControlExt {
    fn terminate(&self, env: &Env, code: i32) -> Result<()>;

    /// Hard process restart via `appRecovery.restartApp()`.
    fn restart(&self, env: &Env) -> Result<()>;

    /// Switches the app color mode: 0 = dark, 1 = light, 2 = follow system.
    fn set_color_mode(&self, env: &Env, mode: i32) -> Result<()>;
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
        self.with_main_thread_bridge(env, |bridge| {
            let response =
                bridge.call_sync::<AppControlBridgePlugin, RestartRequest, RestartResponse>(
                    "restart",
                    RestartRequest { requested: true },
                )?;
            response.ensure()
        })
    }

    fn set_color_mode(&self, env: &Env, mode: i32) -> Result<()> {
        if !(0..=2).contains(&mode) {
            return Err(Error::from_reason(
                "color mode must be 0 (dark), 1 (light) or 2 (follow system)",
            ));
        }
        self.with_main_thread_bridge(env, |bridge| {
            let response =
                bridge.call_sync::<AppControlBridgePlugin, ColorModeRequest, ColorModeResponse>(
                    "set-color-mode",
                    ColorModeRequest { mode },
                )?;
            response.ensure()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{ColorModeRequest, RestartRequest, TerminateRequest, TerminateResponse};
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn app_control_uses_stable_named_napi_contracts() {
        assert_eq!(
            <TerminateRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.TerminateRequest"
        );
        assert_eq!(
            <TerminateResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.TerminateResponse"
        );
        assert_eq!(
            <RestartRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.RestartRequest"
        );
        assert_eq!(
            <ColorModeRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.app_control.ColorModeRequest"
        );
    }

    #[test]
    fn terminate_roundtrip_shape() {
        assert_eq!(TerminateRequest { code: -1 }.code, -1);
        assert!(TerminateResponse { accepted: true }.accepted);
    }
}
