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

#[napi(object)]
#[derive(Clone, Debug)]
pub struct UrlSchemeRequest {
    pub scheme: String,
}

impl_bridge_napi_type!(UrlSchemeRequest, "ohos.url.SchemeRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct UrlSchemeResponse {
    pub declared: bool,
}

impl_bridge_napi_type!(UrlSchemeResponse, "ohos.url.SchemeResponse");

impl UrlOpenResponse {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason("URL plugin rejected the open request"))
        }
    }
}

/// Reveal-in-directory request.
///
/// `path` is the **absolute real filesystem path** of the directory to reveal
/// (the file's parent), e.g. `/storage/media/100/local/files/Docs/IDEProjects`.
/// NOT a `file://` URI — the ArkTS side maps the real path to the file-manager
/// virtual uri and builds the explicit Want. Sandbox or unmappable-prefix
/// paths are rejected ArkTS-side with a documented platform-limitation error.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct UrlRevealRequest {
    pub path: String,
}

impl_bridge_napi_type!(UrlRevealRequest, "ohos.url.RevealRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct UrlOpenFileRequest {
    pub uri: String,
}

impl_bridge_napi_type!(UrlOpenFileRequest, "ohos.url.OpenFileRequest");

fn validate_path(path: &str) -> Result<()> {
    if path.trim().is_empty() {
        return Err(Error::from_reason("path must not be empty"));
    }
    Ok(())
}

fn validate_url(url: &str) -> Result<()> {
    let Some((scheme, remainder)) = url.split_once(':') else {
        return Err(Error::from_reason(
            "url must be an absolute URL with a scheme (e.g. https://... or mailto:...)",
        ));
    };
    normalize_scheme(scheme)?;
    if remainder.is_empty() || url.chars().any(char::is_whitespace) {
        return Err(Error::from_reason("url must contain a non-empty URI value"));
    }
    Ok(())
}

fn normalize_scheme(scheme: &str) -> Result<String> {
    let scheme = scheme.trim();
    let mut chars = scheme.chars();
    if !chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        || !chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    {
        return Err(Error::from_reason(
            "URL scheme must start with a letter and contain only letters, digits, '+', '-' or '.'",
        ));
    }
    Ok(scheme.to_ascii_lowercase())
}

/// Extension trait supplied by the capability package, never by `openharmony-ability` core.
pub trait UrlExt {
    /// Opens an external URL through the system link opener.
    fn open_url(&self, url: impl Into<String>) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    /// Verifies that this Ability declares the scheme in its installed manifest.
    /// OpenHarmony URL schemes cannot be added to a bundle at runtime.
    fn check_url_scheme(
        &self,
        scheme: impl Into<String>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    fn open_file(&self, uri: impl Into<String>)
        -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;

    /// Reveals a directory in the system file manager. `path` must be the
    /// absolute **real filesystem path** of the directory (the file's parent),
    /// not a `file://` URI — the ArkTS side maps it to the file-manager
    /// virtual uri and starts the explicit file-manager Want.
    fn reveal_in_dir(
        &self,
        path: impl Into<String>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;
}

impl UrlExt for OpenHarmonyApp {
    fn check_url_scheme(
        &self,
        scheme: impl Into<String>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let scheme = match normalize_scheme(&scheme.into()) {
            Ok(scheme) => scheme,
            Err(error) => return Box::pin(async move { Err(error) }),
        };
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<UrlBridgePlugin, UrlSchemeRequest, UrlSchemeResponse>(
                    "check-scheme",
                    UrlSchemeRequest {
                        scheme: scheme.clone(),
                    },
                    BridgeCallOptions::default(),
                )
                .await?;
            if response.declared {
                Ok(())
            } else {
                Err(Error::from_reason(format!(
                    "URL scheme '{scheme}' is not declared for this Ability in module.json5"
                )))
            }
        })
    }

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

    fn open_file(
        &self,
        uri: impl Into<String>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let uri = uri.into();
        if !uri.starts_with("file://") {
            return Box::pin(async { Err(Error::from_reason("open_file requires a file:// URI")) });
        }
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<UrlBridgePlugin, UrlOpenFileRequest, UrlOpenResponse>(
                    "open-file",
                    UrlOpenFileRequest { uri },
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }

    fn reveal_in_dir(
        &self,
        path: impl Into<String>,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let path = path.into();
        if let Err(error) = validate_path(&path) {
            return Box::pin(async move { Err(error) });
        }
        let bridge = self.bridge();
        Box::pin(async move {
            let response = bridge?
                .call_async::<UrlBridgePlugin, UrlRevealRequest, UrlOpenResponse>(
                    "reveal-in-dir",
                    UrlRevealRequest { path },
                    BridgeCallOptions::default(),
                )
                .await?;
            response.ensure()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{
        normalize_scheme, validate_url, UrlOpenRequest, UrlOpenResponse, UrlSchemeRequest,
        UrlSchemeResponse,
    };
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
        assert_eq!(
            <UrlSchemeRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.url.SchemeRequest"
        );
        assert_eq!(
            <UrlSchemeResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.url.SchemeResponse"
        );
    }

    #[test]
    fn url_validation_requires_absolute_scheme() {
        assert!(validate_url("https://example.com").is_ok());
        assert!(validate_url("https://example.com/path?a=1").is_ok());
        assert!(validate_url("mailto:hello@example.com").is_ok());
        assert!(validate_url("").is_err());
        assert!(validate_url("example.com").is_err());
        assert!(validate_url("https:").is_err());
    }

    #[test]
    fn scheme_validation_matches_uri_syntax() {
        assert_eq!(normalize_scheme(" GPUI-Demo ").unwrap(), "gpui-demo");
        assert!(normalize_scheme("gpui-demo://open").is_err());
        assert!(normalize_scheme("1invalid").is_err());
        assert!(normalize_scheme("").is_err());
    }
}
