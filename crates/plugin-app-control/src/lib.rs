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
    const VERSION: u32 = 1;
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

/// A synchronous capability must be invoked in an exported N-API callback that owns `Env`.
pub trait AppControlExt {
    fn terminate(&self, env: &Env, code: i32) -> Result<()>;
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
}

#[cfg(test)]
mod tests {
    use super::{TerminateRequest, TerminateResponse};
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
}
