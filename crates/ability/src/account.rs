// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! Huawei Account one-tap login for OpenHarmony via Account Kit (bridge plugin).
//!
//! The ArkTS half (`plugins/account/src/main/ets/AccountPlugin.ets`) is an
//! `AsyncPluginBase` with id `ohos.account` and `requires: ["ability"]`. It wraps
//! `@kit.AccountKit`'s `authentication` service (HuaweiIDProvider /
//! AuthenticationController) and exposes three actions:
//! - `login`       → interactive one-tap login (`forceLogin = true`)
//! - `silentLogin` → silent login, no UI (`forceLogin = false`)
//! - `logout`      → cancels the app's Huawei account authorization
//!   (Account Kit's `createCancelAuthorizationRequest`; see design D8)
//!
//! `login` / `silent_login` return a structured `AccountInfo`; `logout` returns `()`.
//! The `AccountInfo` fields are serialized as camelCase JSON for cross-language
//! transfer.
//!
//! This replaces the former TSFN transport (`helper/account.ets` +
//! `get_account_login_tsfn()` / `get_account_silent_login_tsfn()` /
//! `get_account_logout_tsfn()`). Those globals were never initialized after the
//! `#[ability]` derive refactor — `set_helper` is never called, so the TSFN
//! callbacks could not resolve `helper.accountLogin()` / `accountSilentLogin()` /
//! `accountLogout()`, and every call failed at runtime with "TSFN not
//! initialized". The bridge plugin model routes through
//! `OpenHarmonyApp::bridge()` → `bridgeInvoke`, which is wired up per Ability
//! session.

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use serde::{Deserialize, Serialize};

use crate::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

// ── Plugin identity ────────────────────────────────────────────────────────

/// Core-privileged OHOS capability (not Tauri-shaped).
///
/// First-class OHOS ability exposed on par with `RuntimeInitArgs.app`.
/// Intentionally NOT facade-ized: the API has no Tauri shape (pure OHOS
/// platform capability). Precedent: `OpenHarmonyApp::updater()`.
pub struct AccountBridgePlugin;

impl BridgePlugin for AccountBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.account";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

// ── Request / Response contracts ────────────────────────────────────────────

/// Empty request marker for the `login` / `silentLogin` actions.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct AccountLoginRequest {}

impl_bridge_napi_type!(AccountLoginRequest, "ohos.account.LoginRequest");

/// Response carrying the Account Kit credential fields (camelCase keys, matching
/// the ArkTS `AccountLoginResponse` class). napi-derive emits the JS field names
/// in camelCase (`openId`, `unionId`, `avatarUri`, `authorizationCode`,
/// `accessToken`).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccountLoginResponse {
    pub uid: String,
    pub open_id: String,
    pub union_id: String,
    pub display_name: String,
    pub avatar_uri: String,
    pub authorization_code: String,
    pub access_token: Option<String>,
}

impl_bridge_napi_type!(AccountLoginResponse, "ohos.account.LoginResponse");

impl From<AccountLoginResponse> for AccountInfo {
    fn from(response: AccountLoginResponse) -> Self {
        AccountInfo {
            uid: response.uid,
            open_id: response.open_id,
            union_id: response.union_id,
            display_name: response.display_name,
            avatar_uri: response.avatar_uri,
            authorization_code: response.authorization_code,
            access_token: response.access_token,
        }
    }
}

/// Empty request marker for the `logout` action.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct AccountLogoutRequest {}

impl_bridge_napi_type!(AccountLogoutRequest, "ohos.account.LogoutRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccountLogoutResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(AccountLogoutResponse, "ohos.account.LogoutResponse");

// ── AccountInfo (public serde type) ─────────────────────────────────────────

/// Core-privileged OHOS capability (not Tauri-shaped).
///
/// First-class OHOS ability exposed on par with `RuntimeInitArgs.app`.
/// Intentionally NOT facade-ized: the API has no Tauri shape (pure OHOS
/// platform capability). Precedent: `OpenHarmonyApp::updater()`.
///
/// Account info returned by a successful Huawei Account login.
///
/// All fields except `access_token` are non-optional strings (empty when the
/// Account Kit omits them); `access_token` is only present in some scenarios.
/// Serialized as camelCase JSON for cross-language transfer.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AccountInfo {
    pub uid: String,
    pub open_id: String,
    pub union_id: String,
    pub display_name: String,
    pub avatar_uri: String,
    pub authorization_code: String,
    #[serde(default)]
    pub access_token: Option<String>,
}

// ── HuaweiAccount facade ────────────────────────────────────────────────────

/// Core-privileged OHOS capability (not Tauri-shaped).
///
/// First-class OHOS ability exposed on par with `RuntimeInitArgs.app`.
/// Intentionally NOT facade-ized: the API has no Tauri shape (pure OHOS
/// platform capability). Precedent: `OpenHarmonyApp::updater()`.
///
/// Handle for Huawei Account one-tap login operations.
///
/// Holds a [`BridgeRuntime`] clone obtained from [`OpenHarmonyApp::bridge`].
/// Account Kit has no per-app state beyond the bridge session.
///
/// # Breaking change (2026-08-21)
///
/// `HuaweiAccount::new()` previously took no arguments and relied on global
/// TSFNs initialized during `render()`. Those TSFNs were never wired up after
/// the `#[ability]` derive refactor (`set_helper` is never called), so every
/// call silently failed. The constructor now takes `&OpenHarmonyApp` and
/// resolves the bridge runtime explicitly. Callers must update:
///
/// ```ignore
/// // before
/// let account = HuaweiAccount::new();
/// // after
/// let account = HuaweiAccount::new(app)?;
/// ```
pub struct HuaweiAccount {
    bridge: BridgeRuntime,
}

/// Interactive login timeout. The default 15s bridge timeout fires mid-panel
/// while the user is still typing credentials / SMS codes on the Account Kit
/// login UI (device-verified 2026-08-31: "ohos.account.login timed out after
/// 15000ms" right after a successful panel login).
const INTERACTIVE_LOGIN_TIMEOUT_MS: u32 = 300_000;

impl HuaweiAccount {
    /// Create a new handle bound to the given app's bridge runtime.
    ///
    /// Returns an error if the bridge session is not yet active (call during an
    /// active `NativeAbility` session).
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }

    /// Interactive login — forces the Huawei account login UI (`forceLogin = true`).
    /// Returns the resulting `AccountInfo` on user confirmation.
    ///
    /// Uses a 5-minute bridge timeout: the user may spend minutes on the login
    /// panel (credentials, SMS verification) before the promise resolves.
    pub async fn login(&self) -> Result<AccountInfo> {
        let response = self
            .call_with_options::<AccountLoginRequest, AccountLoginResponse>(
                "login",
                AccountLoginRequest {},
                BridgeCallOptions::default().with_timeout_ms(INTERACTIVE_LOGIN_TIMEOUT_MS),
            )
            .await?;
        Ok(response.into())
    }

    /// Silent login — no UI, succeeds only when the device is already logged in
    /// and the app is already authorized (`forceLogin = false`). Callers should
    /// fall back to `login` on the "not logged in" error (code `1001502001`).
    pub async fn silent_login(&self) -> Result<AccountInfo> {
        let response = self
            .call::<AccountLoginRequest, AccountLoginResponse>(
                "silentLogin",
                AccountLoginRequest {},
            )
            .await?;
        Ok(response.into())
    }

    /// Logout — cancels the app's Huawei account authorization on this device
    /// (Account Kit's `createCancelAuthorizationRequest`, see design D8).
    pub async fn logout(&self) -> Result<()> {
        let response = self
            .call::<AccountLogoutRequest, AccountLogoutResponse>("logout", AccountLogoutRequest {})
            .await?;
        if response.accepted {
            Ok(())
        } else {
            Err(Error::from_reason("account logout rejected by plugin"))
        }
    }

    async fn call<Request, Response>(&self, action: &str, request: Request) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.call_with_options(action, request, BridgeCallOptions::default())
            .await
    }

    async fn call_with_options<Request, Response>(
        &self,
        action: &str,
        request: Request,
        options: BridgeCallOptions,
    ) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.bridge
            .call_async::<AccountBridgePlugin, Request, Response>(action, request, options)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_info_serde_roundtrip() {
        let info = AccountInfo {
            uid: "10001".into(),
            open_id: "OPENID_ABC".into(),
            union_id: "UNIONID_XYZ".into(),
            display_name: "Alice".into(),
            avatar_uri: "https://example.com/a.png".into(),
            authorization_code: "AUTHCODE123".into(),
            access_token: Some("ATOKEN".into()),
        };
        let json = serde_json::to_string(&info).unwrap();
        assert!(json.contains("\"openId\":\"OPENID_ABC\""));
        assert!(json.contains("\"unionId\":\"UNIONID_XYZ\""));
        assert!(json.contains("\"avatarUri\":\"https://example.com/a.png\""));
        assert!(json.contains("\"authorizationCode\":\"AUTHCODE123\""));
        assert!(json.contains("\"accessToken\":\"ATOKEN\""));

        let deserialized: AccountInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized, info);
    }

    #[test]
    fn account_info_optional_access_token_null() {
        // accessToken absent (Account Kit may omit it) → None, no error.
        let json = r#"{"uid":"1","openId":"o","unionId":"u","displayName":"","avatarUri":"","authorizationCode":"c","accessToken":null}"#;
        let info: AccountInfo = serde_json::from_str(json).unwrap();
        assert_eq!(info.access_token, None);
        assert_eq!(info.display_name, "");
    }

    #[test]
    fn account_info_optional_access_token_missing_key() {
        // accessToken key entirely missing → None (#[serde(default)]).
        let json = r#"{"uid":"1","openId":"o","unionId":"u","displayName":"n","avatarUri":"a","authorizationCode":"c"}"#;
        let info: AccountInfo = serde_json::from_str(json).unwrap();
        assert_eq!(info.access_token, None);
        assert_eq!(info.uid, "1");
        assert_eq!(info.display_name, "n");
    }

    #[test]
    fn account_info_default_empty() {
        let info = AccountInfo::default();
        assert_eq!(info.uid, "");
        assert_eq!(info.authorization_code, "");
        assert_eq!(info.access_token, None);
    }

    #[test]
    fn account_response_converts_to_account_info() {
        let response = AccountLoginResponse {
            uid: "10001".into(),
            open_id: "OPENID_ABC".into(),
            union_id: "UNIONID_XYZ".into(),
            display_name: "Alice".into(),
            avatar_uri: "https://example.com/a.png".into(),
            authorization_code: "AUTHCODE123".into(),
            access_token: Some("ATOKEN".into()),
        };
        let info: AccountInfo = response.into();
        assert_eq!(info.uid, "10001");
        assert_eq!(info.open_id, "OPENID_ABC");
        assert_eq!(info.access_token, Some("ATOKEN".to_string()));
    }

    #[test]
    fn account_plugin_targets_ability_context() {
        assert_eq!(AccountBridgePlugin::ID, "ohos.account");
        assert_eq!(
            AccountBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }

    #[test]
    fn account_types_have_stable_named_napi_contracts() {
        assert_eq!(
            <AccountLoginRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.account.LoginRequest"
        );
        assert_eq!(
            <AccountLoginResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.account.LoginResponse"
        );
        assert_eq!(
            <AccountLogoutRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.account.LogoutRequest"
        );
        assert_eq!(
            <AccountLogoutResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.account.LogoutResponse"
        );
    }
}
