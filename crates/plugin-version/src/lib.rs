//! Device version and capability detection plugin facade.
//!
//! Ports the former `crates/ability/src/version.rs` capability into the pluginized bridge
//! model. All queries are synchronous (`MainThreadSyncBridge`) and use process-level device
//! information; ArkTS reads `@ohos.deviceInfo` and the global `canIUse()`.

use napi_derive_ohos::napi;
use napi_ohos::{Env, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, BridgeContextRequirement, BridgePlugin, MainThreadSyncBridge,
    OpenHarmonyApp,
};

pub struct VersionBridgePlugin;

impl BridgePlugin for VersionBridgePlugin {
    type Mode = MainThreadSyncBridge;

    const ID: &'static str = "ohos.version";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] = &[];
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct VersionRequest {
    pub syscap: Option<String>,
}

impl_bridge_napi_type!(VersionRequest, "ohos.version.VersionRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct VersionResponse {
    pub value: i32,
    pub result: Option<bool>,
}

impl_bridge_napi_type!(VersionResponse, "ohos.version.VersionResponse");

fn validate_syscap(syscap: &str) -> Result<()> {
    if syscap.trim().is_empty() {
        return Err(Error::from_reason("syscap must not be empty"));
    }
    Ok(())
}

/// Extension trait supplied by the capability package, never by `openharmony-ability` core.
pub trait VersionExt {
    /// OpenHarmony base API Level (e.g., 12, 14, 20).
    fn sdk_api_version(&self, env: &Env) -> Result<i32>;
    /// HarmonyOS distribution version (`M × 10000 + S × 100 + F`, e.g. 5.0.1 → 50001).
    fn distribution_api_version(&self, env: &Env) -> Result<i32>;
    /// Queries a device system capability through ArkTS `canIUse()`.
    fn can_i_use(&self, env: &Env, syscap: &str) -> Result<bool>;
    /// True when the device is a desktop (2in1) device.
    fn is_desktop_device(&self, env: &Env) -> Result<bool>;
}

impl VersionExt for OpenHarmonyApp {
    fn sdk_api_version(&self, env: &Env) -> Result<i32> {
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<VersionBridgePlugin, VersionRequest, VersionResponse>(
                    "get-sdk-api-version",
                    VersionRequest { syscap: None },
                )?;
            Ok(response.value)
        })
    }

    fn distribution_api_version(&self, env: &Env) -> Result<i32> {
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<VersionBridgePlugin, VersionRequest, VersionResponse>(
                    "get-distribution-api-version",
                    VersionRequest { syscap: None },
                )?;
            Ok(response.value)
        })
    }

    fn can_i_use(&self, env: &Env, syscap: &str) -> Result<bool> {
        validate_syscap(syscap)?;
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<VersionBridgePlugin, VersionRequest, VersionResponse>(
                    "can-i-use",
                    VersionRequest {
                        syscap: Some(syscap.to_owned()),
                    },
                )?;
            Ok(response.result.unwrap_or(false))
        })
    }

    fn is_desktop_device(&self, env: &Env) -> Result<bool> {
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<VersionBridgePlugin, VersionRequest, VersionResponse>(
                    "is-desktop-device",
                    VersionRequest { syscap: None },
                )?;
            Ok(response.result.unwrap_or(false))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{VersionBridgePlugin, VersionRequest, VersionResponse};
    use openharmony_ability::{BridgeNapiType, BridgePlugin};

    #[test]
    fn version_uses_stable_named_napi_contracts() {
        assert_eq!(
            <VersionRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.version.VersionRequest"
        );
        assert_eq!(
            <VersionResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.version.VersionResponse"
        );
    }

    #[test]
    fn version_response_carries_expected_shapes() {
        let sdk = VersionResponse {
            value: 20,
            result: None,
        };
        assert_eq!(sdk.value, 20);
        let capability = VersionResponse {
            value: 0,
            result: Some(true),
        };
        assert!(capability.result.unwrap_or(false));
        assert!(VersionBridgePlugin::REQUIRED_CONTEXTS.is_empty());
    }
}
