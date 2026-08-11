//! Worker-originated synchronous call demo.
//!
//! The same `demo.main-thread` plugin that `main_thread_bridge.rs` inspects from an N-API
//! main-thread callback is invoked here from a Rust worker through the TSFN-backed
//! `BridgeRuntime::call_sync_from_worker` channel. Execution still happens on the ArkTS main
//! thread; only the caller side differs.

use napi_ohos::Result;
use openharmony_ability::BridgeRuntime;

use crate::main_thread_bridge::{
    DemoMainThreadPlugin, MainThreadInspectRequest, MainThreadInspectResponse,
};

/// Runs on a Rust worker: marshals the call to the main thread via TSFN, awaits the
/// synchronous ArkTS response, and formats it for display.
pub async fn inspect_from_worker(bridge: &BridgeRuntime) -> Result<String> {
    let response = bridge
        .call_sync_from_worker::<DemoMainThreadPlugin, MainThreadInspectRequest, MainThreadInspectResponse>(
            "inspect",
            MainThreadInspectRequest { requested: true },
        )
        .await?;
    Ok(format!(
        "worker => session={}, uiContextReady={}, execution={}",
        response.session_id, response.ui_context_ready, response.execution
    ))
}
