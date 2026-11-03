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

/// Rust facade marker for the built-in `ohos.deep-link` plugin (async;
/// requires the Ability context).
pub struct DeepLinkBridgePlugin;

impl BridgePlugin for DeepLinkBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.deep-link";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

// ── Request / Response types ──────────────────────────────────────────────────

/// Empty request marker for `get-current` (the response carries the URI).
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct DeepLinkGetUriRequest {}

impl_bridge_napi_type!(DeepLinkGetUriRequest, "ohos.deep-link.GetUriRequest");

/// Response carrying the want URI that launched the current instance.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct DeepLinkGetUriResponse {
    /// Launch URI, or `None` when the instance was not launched by a deep link.
    pub uri: Option<String>,
}

// Hand-rolled decode instead of `impl_bridge_napi_type!` — same reason as
// UpdaterCheckResponse (crates/ability/src/updater.rs): the
// napi-derive-backend-ohos 1.2.0 object getter infers the item type from the
// assignment target, so a derived `let uri_: Option<String> = obj.get("uri")`
// compiles as `obj.get::<String>` and explodes with `StringExpected` when
// ArkTS sends an explicit `null` — which DeepLinkPlugin.readUri() does for
// the no-deep-link launch, the most common case. A missing property happens
// to work (the getter skips conversion); the explicit turbofish + `flatten()`
// handles present-null, absent, and undefined alike.
impl BridgeNapiType for DeepLinkGetUriResponse {
    const TYPE_NAME: &'static str = "ohos.deep-link.GetUriResponse";

    fn into_bridge_value<'env>(
        self,
        env: &'env napi_ohos::Env,
    ) -> Result<napi_ohos::bindgen_prelude::Unknown<'env>> {
        <Self as napi_ohos::bindgen_prelude::ToNapiValue>::into_unknown(self, env)
    }

    fn from_bridge_value(value: napi_ohos::bindgen_prelude::Unknown<'_>) -> Result<Self> {
        use napi_ohos::bindgen_prelude::{FromNapiValue, Object};
        let obj = Object::from_unknown(value)?;
        let uri: Option<String> = obj.get::<Option<String>>("uri")?.flatten();
        Ok(Self { uri })
    }
}

// ── Client facade ─────────────────────────────────────────────────────────────

/// Worker-safe facade for deep-link URI queries.
#[derive(Clone)]
pub struct DeepLinkClient {
    bridge: BridgeRuntime,
}

impl DeepLinkClient {
    /// Builds a deep-link client bound to the app's bridge session.
    ///
    /// # Errors
    /// Fails when the app has no active bridge session yet.
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
    /// This is a synchronous read of a module-level mutex-guarded static
    /// (`INITIAL_WANT_URI` in the ability crate; no bridge call, no await) —
    /// safe to call from any thread including the main thread. Unlike
    /// [`get_initial_uri`](Self::get_initial_uri), this does NOT go through
    /// the bridge and will not deadlock when called from a sync/main-thread context.
    ///
    /// The value is populated by `onAbilityCreateWithWant` via the lifecycle callback.
    /// Resolves the primary instance's (window id 0) entry; use
    /// [`take_initial_uri_for_window`](Self::take_initial_uri_for_window) for a
    /// spawned instance.
    pub fn take_initial_uri(&self) -> String {
        openharmony_ability::take_initial_want_uri()
    }

    /// Per-instance variant of [`take_initial_uri`](Self::take_initial_uri):
    /// drains the cold-start `want.uri` stored by the UIAbility instance that
    /// owns `window_id` (design.md D9, openspec multi-uiability-windows).
    pub fn take_initial_uri_for_window(&self, window_id: i64) -> String {
        openharmony_ability::take_initial_want_uri_for_window(window_id)
    }

    /// Returns the latest `want.parameters` JSON from `onNewWant`, then clears it.
    ///
    /// This is a synchronous read of a module-level mutex-guarded static
    /// (`WANT_PARAMETERS` in the ability crate; no bridge call, no await) —
    /// safe to call from any thread including the main thread. The value is
    /// populated by the `on_new_want` lifecycle callback.
    pub fn take_want_parameters(&self) -> String {
        openharmony_ability::take_want_parameters()
    }

    /// Per-instance variant of [`take_want_parameters`](Self::take_want_parameters):
    /// drains the `want.parameters` JSON stored by the UIAbility instance that
    /// owns `window_id` (design.md D9).
    pub fn take_want_parameters_for_window(&self, window_id: i64) -> String {
        openharmony_ability::take_want_parameters_for_window(window_id)
    }
}

/// Treats empty strings as `None` so consumers receive `Ok(None)` for normal launches.
fn normalize_uri(uri: Option<String>) -> Option<String> {
    uri.filter(|value| !value.is_empty())
}

/// Resolves a tauri window label to its pre-allocated UIAbility window id
/// (design.md D9, openspec multi-uiability-windows). Labels that never
/// spawned a UIAbility instance — including the primary window — resolve to
/// 0. Re-exported here so deep-link consumers only need this crate.
pub use openharmony_ability::window_id_for_label;

/// Extension trait that adds [`DeepLinkClient`] access to the app handle.
pub trait DeepLinkExt {
    /// Returns the deep-link client bound to this app's bridge session.
    ///
    /// # Errors
    /// Fails when the app has no active bridge session yet.
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
