//! Fault injection facade for coverage testing.
//!
//! This crate is the Rust half of the `ohos.fault-injection` test tooling. Its
//! ArkTS half is the [`plugins/faultinjection`] HAR
//! (`@ohos-rs/ability-plugin-fault-injection`), installed on demand like every
//! other bridge plugin: the app lists a `FaultInjectionPlugin` factory in
//! `NativeAbility#bridgePlugins` and registers the [`FaultInjectionBridgePlugin`]
//! declaration here. Interception runs through the generic `BridgeHost`
//! dispatch-hook seam: the ArkTS plugin registers one hook on install, and the
//! host consults it before every plugin invocation while the registry is
//! enabled. `FAULT_REGISTRY.enabled` defaults to `false` and `match()`
//! short-circuits on its first line, so production builds that never call
//! "enable" pay zero overhead.
//!
//! Only this facade calls the "enable" action to turn injection on; when no
//! rule is ever installed, the registry stays disabled.

use napi_derive_ohos::napi;
use napi_ohos::Result;
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeClient, BridgeContextRequirement,
    BridgeNapiType, BridgePlugin, OpenHarmonyApp,
};
use serde::{Deserialize, Serialize};

// ── Plugin identity ────────────────────────────────────────────────────────

/// Bridge plugin identity for the ArkTS `FaultInjectionPlugin`
/// (`plugins/faultinjection`, `@ohos-rs/ability-plugin-fault-injection`).
pub struct FaultInjectionBridgePlugin;

impl BridgePlugin for FaultInjectionBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.fault-injection";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] = &[];
}

// ── Request / Response contracts ────────────────────────────────────────────

/// Empty request marker for the "enable" / "disable" / "clear" actions.
/// The ArkTS plugin ignores the request value for these actions.
#[napi(object)]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct FaultNoopRequest {}

impl_bridge_napi_type!(FaultNoopRequest, "ohos.fault-injection.NoopRequest");

/// Outcome descriptor — napi-derive emits camelCase keys (`kind`, `code`,
/// `message`, `ms`) matching the ArkTS `FaultOutcome` interface.
///
/// `kind` is one of: `"error"`, `"exception"`, `"delay"`, `"timeout"`.
/// `code`/`message` are used by error/exception; `ms` by delay; timeout uses none.
#[napi(object)]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FaultOutcomeWire {
    pub kind: String,
    pub code: Option<i32>,
    pub message: Option<String>,
    pub ms: Option<u32>,
}

/// Wire format for a fault rule — sent via the "set-rule" action.
/// napi-derive emits camelCase keys (`pluginId`, `action`, `outcome`, `hits`).
#[napi(object)]
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FaultRuleWire {
    pub plugin_id: String,
    pub action: Option<String>,
    pub outcome: FaultOutcomeWire,
    pub hits: Option<i32>,
}

impl_bridge_napi_type!(FaultRuleWire, "ohos.fault-injection.SetRuleRequest");

/// Acknowledgement response — mirrors the ArkTS `FaultInjectionAck` class.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct FaultInjectionAck {
    pub accepted: bool,
}

impl_bridge_napi_type!(FaultInjectionAck, "ohos.fault-injection.Ack");

// ── Facade client ───────────────────────────────────────────────────────────

/// Coverage-testing facade for the fault-injection plugin.
#[derive(Clone)]
pub struct FaultInjectionClient {
    client: BridgeClient,
}

impl FaultInjectionClient {
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            client: app.bridge()?.client(),
        })
    }

    async fn call<Request, Response>(&self, action: &str, request: Request) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.client
            .call_async::<FaultInjectionBridgePlugin, Request, Response>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await
    }

    /// Enables the registry and installs one rule.
    ///
    /// The "enable" action is idempotent — safe to call before every rule, so
    /// callers never need to track registry state. The acknowledgement's
    /// `accepted` flag is deliberately not checked (parity with the former
    /// `OpenHarmonyApp::set_fault_rule`).
    pub async fn set_fault_rule(&self, rule: FaultRuleWire) -> Result<()> {
        self.call::<FaultNoopRequest, FaultInjectionAck>("enable", FaultNoopRequest {})
            .await?;
        self.call::<FaultRuleWire, FaultInjectionAck>("set-rule", rule)
            .await?;
        Ok(())
    }

    /// Clears all installed rules (the registry stays enabled).
    pub async fn clear_fault_rules(&self) -> Result<()> {
        self.call::<FaultNoopRequest, FaultInjectionAck>("clear", FaultNoopRequest {})
            .await?;
        Ok(())
    }
}

pub trait FaultInjectionExt {
    /// Coverage-testing fault injection against the `ohos.fault-injection`
    /// plugin. The plugin must be registered
    /// (`register_plugin(FaultInjectionBridgePlugin)`) and its ArkTS factory
    /// listed in `NativeAbility#bridgePlugins`.
    fn fault_injection(&self) -> Result<FaultInjectionClient>;
}

impl FaultInjectionExt for OpenHarmonyApp {
    fn fault_injection(&self) -> Result<FaultInjectionClient> {
        FaultInjectionClient::new(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_plugin_contract_is_stable() {
        assert_eq!(FaultInjectionBridgePlugin::ID, "ohos.fault-injection");
        assert!(FaultInjectionBridgePlugin::REQUIRED_CONTEXTS.is_empty());
    }

    #[test]
    fn wire_types_have_stable_named_napi_contracts() {
        assert_eq!(
            <FaultNoopRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.fault-injection.NoopRequest"
        );
        assert_eq!(
            <FaultRuleWire as BridgeNapiType>::TYPE_NAME,
            "ohos.fault-injection.SetRuleRequest"
        );
        assert_eq!(
            <FaultInjectionAck as BridgeNapiType>::TYPE_NAME,
            "ohos.fault-injection.Ack"
        );
    }

    #[test]
    fn fault_rule_wire_roundtrips_with_camel_case_keys() {
        let rule = FaultRuleWire {
            plugin_id: "ohos.clipboard".to_owned(),
            action: Some("read-text".to_owned()),
            outcome: FaultOutcomeWire {
                kind: "error".to_owned(),
                code: Some(42),
                message: Some("injected".to_owned()),
                ms: None,
            },
            hits: Some(3),
        };
        let json = serde_json::to_value(&rule).unwrap();
        assert_eq!(json["pluginId"], "ohos.clipboard");
        assert_eq!(json["action"], "read-text");
        assert_eq!(json["outcome"]["kind"], "error");
        assert_eq!(json["outcome"]["code"], 42);
        assert_eq!(json["hits"], 3);
        let decoded: FaultRuleWire = serde_json::from_value(json).unwrap();
        assert_eq!(decoded.plugin_id, rule.plugin_id);
        assert_eq!(decoded.outcome.code, Some(42));
        assert_eq!(decoded.hits, Some(3));
    }
}
