//! External URL open capability plugin facade.
//!
//! Ports the `openURL` half of PR #65 (native platform URL service) into the pluginized
//! bridge model. The ArkTS side resolves the system link opener (`openLink`); Rust only
//! carries the URL string and an acknowledgement.

use std::{future::Future, pin::Pin};

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement, BridgePlugin,
    OpenHarmonyApp,
};

pub struct UrlBridgePlugin;

impl BridgePlugin for UrlBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.url";
    const VERSION: u32 = 1;
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct UrlOpenRequest {
    pub url: String,
}

impl_bridge_napi_type!(UrlOpenRequest, "ohos.url.OpenRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct UrlOpenResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(UrlOpenResponse, "ohos.url.OpenResponse");

impl UrlOpenResponse {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason("URL plugin rejected the open request"))
        }
    }
}

fn validate_url(url: &str) -> Result<()> {
    if url.trim().is_empty() {
        return Err(Error::from_reason("url must not be empty"));
    }
    if !url.contains("://") {
        return Err(Error::from_reason(
            "url must be an absolute URL with a scheme (e.g. https://...)",
        ));
    }
    Ok(())
}

/// Extension trait supplied by the capability package, never by `openharmony-ability` core.
pub trait UrlExt {
    /// Opens an external URL through the system link opener.
    fn open_url(&self, url: impl Into<String>) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;
}

impl UrlExt for OpenHarmonyApp {
    fn open_url(&self, url: impl Into<String>) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let url = url.into();
        if let Err(error) = validate_url(&url) {
            return Box::pin(async move { Err(error) });
        }
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<UrlBridgePlugin, UrlOpenRequest, UrlOpenResponse>(
                    "open-url",
                    UrlOpenRequest { url },
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{validate_url, UrlOpenRequest, UrlOpenResponse};
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn url_uses_stable_named_napi_contracts() {
        assert_eq!(
            <UrlOpenRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.url.OpenRequest"
        );
        assert_eq!(
            <UrlOpenResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.url.OpenResponse"
        );
    }

    #[test]
    fn url_validation_requires_absolute_scheme() {
        assert!(validate_url("https://example.com").is_ok());
        assert!(validate_url("https://example.com/path?a=1").is_ok());
        assert!(validate_url("").is_err());
        assert!(validate_url("example.com").is_err());
    }
}
