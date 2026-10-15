//! Asynchronous autostart bridge plugin facade.
//!
//! Provides `enable`, `disable`, and `is-enabled` actions through the bridge plugin model.
//! The ArkTS side uses `autoStartupManager.getAutoStartupStatusForSelf()` (API 21+) for status
//! queries and `context.startAbility(want)` to navigate to the system "App Startup Management"
//! settings page for enable/disable.
//!
//! Version guard: `is_enabled` requires API 21+; on lower API levels it returns `Ok(false)`.
//! `enable` / `disable` have no version guard — `startAbility` is available from API 12+.

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, version, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

/// Minimum API level for `autoStartupManager.getAutoStartupStatusForSelf()`.
const MIN_AUTOSTART_API_VERSION: i32 = 21;

// ── Bridge plugin declaration ─────────────────────────────────────────────────

pub struct AutostartBridgePlugin;

impl BridgePlugin for AutostartBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.autostart";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

// ── enable ────────────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct AutostartEnableRequest {}

impl_bridge_napi_type!(AutostartEnableRequest, "ohos.autostart.EnableRequest");

// ── disable ───────────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct AutostartDisableRequest {}

impl_bridge_napi_type!(AutostartDisableRequest, "ohos.autostart.DisableRequest");

// ── is-enabled ─────────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct AutostartIsEnabledRequest {}

impl_bridge_napi_type!(AutostartIsEnabledRequest, "ohos.autostart.IsEnabledRequest");

// ── acknowledgement ───────────────────────────────────────────────────────────

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

// ── is-enabled response ───────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AutostartIsEnabledResponse {
    pub enabled: bool,
}

impl_bridge_napi_type!(
    AutostartIsEnabledResponse,
    "ohos.autostart.IsEnabledResponse"
);

// ── Client facade ─────────────────────────────────────────────────────────────

/// Worker-safe facade for the system autostart manager.
#[derive(Clone)]
pub struct AutostartClient {
    bridge: BridgeRuntime,
}

impl AutostartClient {
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }

    async fn call<Request, Response>(&self, action: &str, request: Request) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.bridge
            .call_async::<AutostartBridgePlugin, Request, Response>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await
    }

    /// Opens the system "App Startup Management" settings page so the user can
    /// manually enable autostart for this application.
    ///
    /// OHOS does not allow ordinary apps to programmatically enable autostart;
    /// this method reflects user intent rather than guaranteeing the result.
    pub async fn enable(&self) -> Result<()> {
        let response = self
            .call::<AutostartEnableRequest, AutostartAcknowledgement>(
                "enable",
                AutostartEnableRequest {},
            )
            .await?;
        response.ensure()
    }

    /// Opens the system "App Startup Management" settings page so the user can
    /// manually disable autostart for this application.
    ///
    /// `disable` navigates to the same settings page as `enable` — OHOS does not
    /// expose a programmatic disable API. The method name reflects user intent.
    pub async fn disable(&self) -> Result<()> {
        let response = self
            .call::<AutostartDisableRequest, AutostartAcknowledgement>(
                "disable",
                AutostartDisableRequest {},
            )
            .await?;
        response.ensure()
    }

    /// Queries whether autostart is enabled for this application.
    ///
    /// Requires API 21+ (`autoStartupManager.getAutoStartupStatusForSelf()`).
    /// On lower API levels, returns `Ok(false)` as a forced fallback.
    /// On devices that do not support `autoStartupManager` (error 801), also returns `Ok(false)`.
    pub async fn is_enabled(&self) -> Result<bool> {
        if version::sdk_api_version() < MIN_AUTOSTART_API_VERSION {
            return Ok(false);
        }
        let response = self
            .call::<AutostartIsEnabledRequest, AutostartIsEnabledResponse>(
                "is-enabled",
                AutostartIsEnabledRequest {},
            )
            .await?;
        Ok(response.enabled)
    }
}

pub trait AutostartExt {
    fn autostart(&self) -> Result<AutostartClient>;
}

impl AutostartExt for OpenHarmonyApp {
    fn autostart(&self) -> Result<AutostartClient> {
        AutostartClient::new(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn autostart_plugin_targets_ability_context() {
        assert_eq!(AutostartBridgePlugin::ID, "ohos.autostart");
        assert_eq!(
            AutostartBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }

    #[test]
    fn autostart_types_have_stable_named_napi_contracts() {
        assert_eq!(
            <AutostartEnableRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.autostart.EnableRequest"
        );
        assert_eq!(
            <AutostartDisableRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.autostart.DisableRequest"
        );
        assert_eq!(
            <AutostartIsEnabledRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.autostart.IsEnabledRequest"
        );
        assert_eq!(
            <AutostartAcknowledgement as BridgeNapiType>::TYPE_NAME,
            "ohos.autostart.Acknowledgement"
        );
        assert_eq!(
            <AutostartIsEnabledResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.autostart.IsEnabledResponse"
        );
    }

    #[test]
    fn acknowledgement_ensure_rejects_false() {
        let ack = AutostartAcknowledgement { accepted: false };
        assert!(ack.ensure().is_err());
    }

    #[test]
    fn acknowledgement_ensure_accepts_true() {
        let ack = AutostartAcknowledgement { accepted: true };
        assert!(ack.ensure().is_ok());
    }
}
