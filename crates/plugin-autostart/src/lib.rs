//! Autostart settings capability plugin facade.
//!
//! Ordinary applications cannot toggle autostart directly. `open-settings` navigates to the
//! platform app-launch settings page, while `is-enabled` queries the API 21+ status surface.

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, sdk_api_version, AsyncBridge, BridgeCallOptions,
    BridgeContextRequirement, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

pub struct AutostartBridgePlugin;

impl BridgePlugin for AutostartBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.autostart";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AutostartRequest {
    pub requested: bool,
}

impl_bridge_napi_type!(AutostartRequest, "ohos.autostart.Request");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AutostartAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(AutostartAcknowledgement, "ohos.autostart.Acknowledgement");

impl AutostartAcknowledgement {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "Autostart plugin rejected the requested operation",
            ))
        }
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AutostartStatusResponse {
    pub enabled: bool,
    pub supported: bool,
}

impl_bridge_napi_type!(AutostartStatusResponse, "ohos.autostart.StatusResponse");

/// Public status result that distinguishes an unavailable platform API from a disabled switch.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AutostartStatus {
    pub enabled: bool,
    pub supported: bool,
}

/// Worker-safe autostart client scoped to the current `OpenHarmonyApp` bridge registry.
#[derive(Clone)]
pub struct AutostartManager {
    bridge: BridgeRuntime,
}

impl AutostartManager {
    fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }

    /// Opens the system app-launch management page. The user performs the actual toggle there.
    pub async fn open_settings(&self) -> Result<()> {
        self.bridge
            .call_async::<AutostartBridgePlugin, AutostartRequest, AutostartAcknowledgement>(
                "open-settings",
                AutostartRequest { requested: true },
                BridgeCallOptions::default(),
            )
            .await?
            .ensure()
    }

    /// Compatibility alias: OpenHarmony requires the user to enable autostart in settings.
    pub async fn enable(&self) -> Result<()> {
        self.open_settings().await
    }

    /// Compatibility alias: OpenHarmony requires the user to disable autostart in settings.
    pub async fn disable(&self) -> Result<()> {
        self.open_settings().await
    }

    /// Queries the current autostart status and whether this device exposes the API.
    pub async fn status(&self) -> Result<AutostartStatus> {
        if sdk_api_version() < 21 {
            return Ok(AutostartStatus {
                enabled: false,
                supported: false,
            });
        }
        let response = self
            .bridge
            .call_async::<AutostartBridgePlugin, AutostartRequest, AutostartStatusResponse>(
                "is-enabled",
                AutostartRequest { requested: true },
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(AutostartStatus {
            enabled: response.enabled,
            supported: response.supported,
        })
    }

    /// Compatibility query: unsupported devices are reported as disabled.
    pub async fn is_enabled(&self) -> Result<bool> {
        let status = self.status().await?;
        Ok(status.supported && status.enabled)
    }
}

/// Extension trait supplied by the capability package, never by framework core.
pub trait AutostartExt {
    fn autostart(&self) -> Result<AutostartManager>;
}

impl AutostartExt for OpenHarmonyApp {
    fn autostart(&self) -> Result<AutostartManager> {
        AutostartManager::new(self)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        AutostartAcknowledgement, AutostartBridgePlugin, AutostartRequest, AutostartStatusResponse,
    };
    use openharmony_ability::{BridgeContextRequirement, BridgeNapiType, BridgePlugin};

    #[test]
    fn autostart_uses_stable_named_napi_contracts() {
        assert_eq!(
            <AutostartRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.autostart.Request"
        );
        assert_eq!(
            <AutostartAcknowledgement as BridgeNapiType>::TYPE_NAME,
            "ohos.autostart.Acknowledgement"
        );
        assert_eq!(
            <AutostartStatusResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.autostart.StatusResponse"
        );
        assert_eq!(
            AutostartBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }

    #[test]
    fn autostart_rejects_negative_acknowledgement() {
        assert!(AutostartAcknowledgement { accepted: true }.ensure().is_ok());
        assert!(AutostartAcknowledgement { accepted: false }
            .ensure()
            .is_err());
    }
}
