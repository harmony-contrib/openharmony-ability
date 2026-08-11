//! Named N-API type demo for the generic bridge.

use napi_derive_ohos::napi;
use napi_ohos::Result;
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement, BridgePlugin,
    BridgeRuntime,
};

pub struct DemoTypedPlugin;

impl BridgePlugin for DemoTypedPlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "demo.raw";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] = &[];
}

pub async fn echo_string(bridge: BridgeRuntime, value: impl Into<String>) -> Result<String> {
    bridge
        .call_async::<DemoTypedPlugin, String, String>(
            "echo-string",
            value.into(),
            BridgeCallOptions::default(),
        )
        .await
}

pub async fn reverse_bytes(bridge: BridgeRuntime, value: impl Into<Vec<u8>>) -> Result<Vec<u8>> {
    bridge
        .call_async::<DemoTypedPlugin, Vec<u8>, Vec<u8>>(
            "reverse-bytes",
            value.into(),
            BridgeCallOptions::default(),
        )
        .await
}

/// This is passed to ArkTS as a real N-API object, not as JSON. The explicit bridge name makes
/// the contract stable even if the Rust struct/module name changes.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct DemoProfile {
    pub user_id: String,
    pub visit_count: i32,
}

impl_bridge_napi_type!(DemoProfile, "demo.Profile");

pub async fn bump_profile(bridge: BridgeRuntime, profile: DemoProfile) -> Result<DemoProfile> {
    bridge
        .call_async::<DemoTypedPlugin, DemoProfile, DemoProfile>(
            "bump-profile",
            profile,
            BridgeCallOptions::default(),
        )
        .await
}
