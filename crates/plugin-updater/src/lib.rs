//! AppGallery updater capability plugin facade.
//!
//! Ports the former `crates/ability/src/updater.rs` + `helper/updater.rs` capability into
//! the pluginized bridge model. ArkTS uses `@kit.AppGalleryKit` `updateManager`.

use std::{future::Future, pin::Pin};

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement, BridgePlugin,
    OpenHarmonyApp,
};

pub struct UpdaterBridgePlugin;

impl BridgePlugin for UpdaterBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.updater";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct UpdaterCheckRequest {
    pub requested: bool,
}

impl_bridge_napi_type!(UpdaterCheckRequest, "ohos.updater.CheckRequest");

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct UpdaterCheckResult {
    pub update_available: bool,
    pub current_version: String,
    pub version: String,
    pub body: Option<String>,
    pub date: Option<String>,
}

impl_bridge_napi_type!(UpdaterCheckResult, "ohos.updater.CheckResult");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct UpdaterCheckResponse {
    pub result: Option<UpdaterCheckResult>,
}

impl_bridge_napi_type!(UpdaterCheckResponse, "ohos.updater.CheckResponse");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct UpdaterAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(UpdaterAcknowledgement, "ohos.updater.Acknowledgement");

impl UpdaterAcknowledgement {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "Updater plugin rejected the requested operation",
            ))
        }
    }
}

/// Extension trait supplied by the capability package, never by `openharmony-ability` core.
pub trait UpdaterExt {
    /// Checks AppGallery for an available update. Pure query, no dialog.
    fn check(&self) -> Pin<Box<dyn Future<Output = Result<Option<UpdaterCheckResult>>> + Send>>;
    /// Shows the AppGallery update dialog and drives the download + install flow.
    fn download_and_install(&self) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;
}

impl UpdaterExt for OpenHarmonyApp {
    fn check(&self) -> Pin<Box<dyn Future<Output = Result<Option<UpdaterCheckResult>>> + Send>> {
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<UpdaterBridgePlugin, UpdaterCheckRequest, UpdaterCheckResponse>(
                    "check",
                    UpdaterCheckRequest { requested: true },
                    BridgeCallOptions::default().with_timeout_ms(60_000),
                )
                .await?;
            Ok(response.result)
        })
    }

    fn download_and_install(&self) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<UpdaterBridgePlugin, UpdaterCheckRequest, UpdaterAcknowledgement>(
                    "download-and-install",
                    UpdaterCheckRequest { requested: true },
                    BridgeCallOptions::default().with_timeout_ms(60_000),
                )
                .await?;
            response.ensure()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{UpdaterCheckRequest, UpdaterCheckResponse, UpdaterCheckResult};
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn updater_uses_stable_named_napi_contracts() {
        assert_eq!(
            <UpdaterCheckRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.updater.CheckRequest"
        );
        assert_eq!(
            <UpdaterCheckResult as BridgeNapiType>::TYPE_NAME,
            "ohos.updater.CheckResult"
        );
        assert_eq!(
            <UpdaterCheckResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.updater.CheckResponse"
        );
    }

    #[test]
    fn updater_check_result_roundtrip() {
        let result = UpdaterCheckResult {
            update_available: true,
            current_version: "1.0.0".to_owned(),
            version: "2.0.0".to_owned(),
            body: Some("Bug fixes".to_owned()),
            date: Some("2025-01-15".to_owned()),
        };
        assert!(result.update_available);
        assert_eq!(result.version, "2.0.0");
        let response = UpdaterCheckResponse {
            result: Some(result),
        };
        assert!(response.result.is_some());
        let none = UpdaterCheckResponse { result: None };
        assert!(none.result.is_none());
    }
}
