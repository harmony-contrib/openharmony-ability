//! Main-thread-only Rust facade for the `demo.main-thread` ArkTS plugin.

use napi_derive_ohos::napi;
use napi_ohos::{Env, Result};
use openharmony_ability::{
    impl_bridge_napi_type, BridgeContextRequirement, BridgePlugin, MainThreadSyncBridge,
    OpenHarmonyApp,
};

pub struct DemoMainThreadPlugin;

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MainThreadInspectRequest {
    pub requested: bool,
}

impl_bridge_napi_type!(MainThreadInspectRequest, "demo.main-thread.InspectRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MainThreadInspectResponse {
    pub session_id: String,
    pub ui_context_ready: bool,
    pub execution: String,
}

impl_bridge_napi_type!(
    MainThreadInspectResponse,
    "demo.main-thread.InspectResponse"
);

impl BridgePlugin for DemoMainThreadPlugin {
    type Mode = MainThreadSyncBridge;

    const ID: &'static str = "demo.main-thread";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::UiContext];
}

/// This requires `Env`, so it can only be called from an exported N-API callback on the main
/// thread. Workers invoke the same plugin through `BridgeRuntime::call_sync_from_worker`
/// (see `tsfn_sync_bridge.rs`).
pub fn inspect_from_napi_main_thread(app: &OpenHarmonyApp, env: &Env) -> Result<String> {
    app.with_main_thread_bridge(env, |bridge| {
        let response = bridge
            .call_sync::<DemoMainThreadPlugin, MainThreadInspectRequest, MainThreadInspectResponse>(
                "inspect",
                MainThreadInspectRequest { requested: true },
            )?;
        Ok(format!(
            "session={}, uiContextReady={}, execution={}",
            response.session_id, response.ui_context_ready, response.execution
        ))
    })
}
