//! Asynchronous deep link bridge plugin facade.
//!
//! Provides `get-initial-uri` and `get-latest-uri` actions through the bridge plugin model.
//! The ArkTS side reads `AppStorage` entries populated by `NativeAbility.onCreate` (cold-start
//! URI) and `NativeAbility.onNewWant` (latest URI).
//!
//! No version guard is required — `want.uri` is an API 12 native field.

use napi_derive_ohos::napi;
use napi_ohos::Result;
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

// ── Bridge plugin declaration ─────────────────────────────────────────────────

pub struct DeepLinkBridgePlugin;

impl BridgePlugin for DeepLinkBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.deep-link";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

// ── Request / Response types ──────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct DeepLinkGetUriRequest {}

impl_bridge_napi_type!(DeepLinkGetUriRequest, "ohos.deep-link.GetUriRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct DeepLinkGetUriResponse {
    pub uri: Option<String>,
}

impl_bridge_napi_type!(DeepLinkGetUriResponse, "ohos.deep-link.GetUriResponse");

// ── Client facade ─────────────────────────────────────────────────────────────

/// Worker-safe facade for deep-link URI queries.
#[derive(Clone)]
pub struct DeepLinkClient {
    bridge: BridgeRuntime,
    /// App handle for the Rust-side want state (issue #87 major-9: migrated
    /// from module statics into `OpenHarmonyAppInner`).
    app: OpenHarmonyApp,
}

impl DeepLinkClient {
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
            app: app.clone(),
        })
    }

    async fn call<Request, Response>(&self, action: &str, request: Request) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.bridge
            .call_async::<DeepLinkBridgePlugin, Request, Response>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await
    }

    /// Returns the cold-start `want.uri` that launched the application.
    ///
    /// This value is captured once by `NativeAbility.onCreate` and stored in
    /// `AppStorage("initialWantUri")`. Subsequent `onNewWant` deliveries do not
    /// overwrite it, so `get_initial_uri` always returns the cold-start value.
    pub async fn get_initial_uri(&self) -> Result<Option<String>> {
        let response = self
            .call::<DeepLinkGetUriRequest, DeepLinkGetUriResponse>(
                "get-initial-uri",
                DeepLinkGetUriRequest {},
            )
            .await?;
        Ok(normalize_uri(response.uri))
    }

    /// Returns the latest `want.uri` received by the application.
    ///
    /// This is initially the cold-start URI, updated by each `onNewWant` delivery.
    /// The value is stored in `AppStorage("wantUri")`.
    pub async fn get_latest_uri(&self) -> Result<Option<String>> {
        let response = self
            .call::<DeepLinkGetUriRequest, DeepLinkGetUriResponse>(
                "get-latest-uri",
                DeepLinkGetUriRequest {},
            )
            .await?;
        Ok(normalize_uri(response.uri))
    }

    /// Returns the cold-start `want.uri` from the app's session state, then clears it.
    ///
    /// This is a **synchronous** RwLock read — safe to call from any thread including the
    /// main thread. Unlike [`get_initial_uri`](Self::get_initial_uri), this does NOT go
    /// through the bridge and will not deadlock when called from a sync/main-thread context.
    ///
    /// The value is populated by `onAbilityCreateWithWant` via the lifecycle callback.
    pub fn take_initial_uri(&self) -> String {
        self.app.take_initial_want_uri()
    }

    /// Returns the latest `want.parameters` JSON from `onNewWant`, then clears it.
    ///
    /// This is a **synchronous** RwLock read — safe to call from any thread including the
    /// main thread. The value is populated by the `on_new_want` lifecycle callback.
    pub fn take_want_parameters(&self) -> String {
        self.app.take_want_parameters()
    }
}

/// Treats empty strings as `None` so consumers receive `Ok(None)` for normal launches.
fn normalize_uri(uri: Option<String>) -> Option<String> {
    uri.filter(|value| !value.is_empty())
}

pub trait DeepLinkExt {
    fn deep_link(&self) -> Result<DeepLinkClient>;
}

impl DeepLinkExt for OpenHarmonyApp {
    fn deep_link(&self) -> Result<DeepLinkClient> {
        DeepLinkClient::new(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deep_link_plugin_targets_ability_context() {
        assert_eq!(DeepLinkBridgePlugin::ID, "ohos.deep-link");
        assert_eq!(
            DeepLinkBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }

    #[test]
    fn deep_link_types_have_stable_named_napi_contracts() {
        assert_eq!(
            <DeepLinkGetUriRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.deep-link.GetUriRequest"
        );
        assert_eq!(
            <DeepLinkGetUriResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.deep-link.GetUriResponse"
        );
    }

    #[test]
    fn normalize_uri_treats_empty_as_none() {
        assert_eq!(normalize_uri(None), None);
        assert_eq!(normalize_uri(Some(String::new())), None);
        assert_eq!(
            normalize_uri(Some("myapp://page".to_owned())),
            Some("myapp://page".to_owned())
        );
    }
}
