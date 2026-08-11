//! Rust facade for the application-owned `demo.login` ArkTS bridge plugin.
//!
//! This module intentionally lives in the demo native library rather than in
//! `openharmony-ability`: the framework only owns transport and lifecycle, while the plugin owns
//! the login protocol and business semantics.

use std::sync::atomic::{AtomicU64, Ordering};

use napi_derive_ohos::napi;
use napi_ohos::Result;
use ohos_hilog_binding::hilog_info;
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgePlugin, BridgeRuntime,
    PluginLifecycleEvent,
};

pub struct DemoLoginPlugin;

impl BridgePlugin for DemoLoginPlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "demo.login";

    fn on_lifecycle(&self, event: &PluginLifecycleEvent) -> Result<()> {
        hilog_info!(format!("demo.login lifecycle => {event:?}").as_str());
        Ok(())
    }
}

static MAIN_THREAD_LOGIN_COMMITS: AtomicU64 = AtomicU64::new(0);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct LoginRequest {
    pub provider: String,
    pub scopes: Vec<String>,
}

impl_bridge_napi_type!(LoginRequest, "demo.login.LoginRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct LoginResponse {
    pub user_id: String,
    pub display_name: String,
    pub access_token: String,
    pub expires_at_ms: i64,
}

impl_bridge_napi_type!(LoginResponse, "demo.login.LoginResponse");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct LoginPublishResponse {
    pub published: bool,
}

impl_bridge_napi_type!(LoginPublishResponse, "demo.login.LoginPublishResponse");

/// Runs the complete login sequence from a Rust worker thread.
///
/// `authorize` and `publish` are both marshalled through the generic TSFN to ArkTS. The small
/// state commit between them uses the generic main-thread scheduler, demonstrating the reverse
/// worker -> main transition without calling N-API or retaining a Helper object on the worker.
pub async fn login_from_worker(bridge: BridgeRuntime) -> Result<String> {
    let options = BridgeCallOptions::default().with_timeout_ms(10_000);
    let response = bridge
        .call_async::<DemoLoginPlugin, LoginRequest, LoginResponse>(
            "authorize",
            LoginRequest {
                provider: "demo".to_owned(),
                scopes: vec!["profile".to_owned(), "email".to_owned()],
            },
            options,
        )
        .await?;
    let access_token = response.access_token.clone();

    bridge
        .main_thread()
        .run(|| {
            MAIN_THREAD_LOGIN_COMMITS.fetch_add(1, Ordering::SeqCst);
        })
        .await?;

    bridge
        .call_async::<DemoLoginPlugin, LoginResponse, LoginPublishResponse>(
            "publish", response, options,
        )
        .await?;

    Ok(access_token)
}

#[allow(dead_code)]
pub fn main_thread_login_commit_count() -> u64 {
    MAIN_THREAD_LOGIN_COMMITS.load(Ordering::SeqCst)
}
