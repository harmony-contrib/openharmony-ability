//! Typed Rust facade for the ArkTS `@ohos-rs/plugin-permission` HAR.
//!
//! This crate deliberately depends on the bridge core; the core does not depend on this crate.

use std::{future::Future, pin::Pin};

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement, BridgePlugin,
    OpenHarmonyApp,
};

pub struct PermissionBridgePlugin;

impl BridgePlugin for PermissionBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.permission";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PermissionRequest {
    One(String),
    Many(Vec<String>),
}

impl PermissionRequest {
    pub fn permissions(self) -> Vec<String> {
        match self {
            Self::One(permission) => vec![permission],
            Self::Many(permissions) => permissions,
        }
    }
}

impl From<String> for PermissionRequest {
    fn from(permission: String) -> Self {
        Self::One(permission)
    }
}

impl From<&str> for PermissionRequest {
    fn from(permission: &str) -> Self {
        Self::One(permission.to_owned())
    }
}

impl From<Vec<String>> for PermissionRequest {
    fn from(permissions: Vec<String>) -> Self {
        Self::Many(permissions)
    }
}

impl<'a> From<Vec<&'a str>> for PermissionRequest {
    fn from(permissions: Vec<&'a str>) -> Self {
        Self::Many(permissions.into_iter().map(str::to_owned).collect())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PermissionRequestCode {
    pub permission: String,
    pub code: i32,
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct PermissionRequestPayload {
    pub permissions: Vec<String>,
}

impl_bridge_napi_type!(
    PermissionRequestPayload,
    "ohos.permission.PermissionRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct PermissionResponsePayload {
    pub codes: Vec<i32>,
}

impl_bridge_napi_type!(
    PermissionResponsePayload,
    "ohos.permission.PermissionResponse"
);

fn validate_request(permissions: &[String]) -> Result<()> {
    if permissions.is_empty()
        || permissions
            .iter()
            .any(|permission| permission.trim().is_empty())
    {
        return Err(Error::from_reason(
            "Permission requests must contain one or more non-empty permission names",
        ));
    }
    Ok(())
}

/// Extension trait supplied by the capability package, never by `openharmony-ability` core.
pub trait PermissionExt {
    fn request_permission<P>(
        &self,
        permission: P,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<PermissionRequestCode>>> + Send>>
    where
        P: Into<PermissionRequest>;
}

impl PermissionExt for OpenHarmonyApp {
    fn request_permission<P>(
        &self,
        permission: P,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<PermissionRequestCode>>> + Send>>
    where
        P: Into<PermissionRequest>,
    {
        let permissions = permission.into().permissions();
        let payload = validate_request(&permissions).map(|()| PermissionRequestPayload {
            permissions: permissions.clone(),
        });
        let bridge = self.bridge();

        Box::pin(async move {
            let response = bridge?
                .call_async::<
                    PermissionBridgePlugin,
                    PermissionRequestPayload,
                    PermissionResponsePayload,
                >(
                    "request",
                    payload?,
                    BridgeCallOptions::default().with_timeout_ms(60_000),
                )
                .await?;
            let codes = response.codes;
            if codes.len() != permissions.len() {
                return Err(Error::from_reason(format!(
                    "Permission plugin returned {} results for {} requested permissions",
                    codes.len(),
                    permissions.len()
                )));
            }

            Ok(permissions
                .into_iter()
                .zip(codes)
                .map(|(permission, code)| PermissionRequestCode { permission, code })
                .collect())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{
        validate_request, PermissionRequest, PermissionRequestPayload, PermissionResponsePayload,
    };
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn permission_request_preserves_order_and_rejects_invalid_names() {
        let permissions =
            PermissionRequest::from(vec!["ohos.permission.CAMERA", "ohos.permission.MICROPHONE"])
                .permissions();
        assert_eq!(
            permissions,
            vec![
                "ohos.permission.CAMERA".to_owned(),
                "ohos.permission.MICROPHONE".to_owned(),
            ]
        );
        assert!(validate_request(&permissions).is_ok());
        assert!(validate_request(&[]).is_err());
        assert!(validate_request(&[" ".to_owned()]).is_err());
    }

    #[test]
    fn permission_uses_stable_named_napi_contracts() {
        assert_eq!(
            <PermissionRequestPayload as BridgeNapiType>::TYPE_NAME,
            "ohos.permission.PermissionRequest"
        );
        assert_eq!(
            <PermissionResponsePayload as BridgeNapiType>::TYPE_NAME,
            "ohos.permission.PermissionResponse"
        );
    }
}
