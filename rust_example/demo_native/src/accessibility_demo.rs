//! Worker-safe announcement and reduced-motion observation assembly.
use napi_derive_ohos::napi;
use napi_ohos::Result;
use openharmony_ability_plugin_accessibility::{
    AccessibilityClient, AccessibilityMotionObservation, AccessibilitySendEventRequest,
};
use std::sync::{LazyLock, Mutex};
static MOTION: LazyLock<Mutex<Option<AccessibilityMotionObservation>>> =
    LazyLock::new(|| Mutex::new(None));
/// Speaks a native announcement through the paired API-12 plugin.
#[napi]
pub async fn demo_announce(text: String) -> Result<()> {
    AccessibilityClient::new(&super::current_app()?)?
        .send_event(AccessibilitySendEventRequest {
            announcement: Some(text),
            element_id: None,
        })
        .await
}
/// Logs initial and changed API-23 reduced-motion state.
#[napi]
pub async fn demo_observe_motion() -> Result<()> {
    let observation = AccessibilityClient::new(&super::current_app()?)?
        .observe_reduce_motion(|enabled| {
            log::info!("reduced motion: {enabled}");
        })
        .await?;
    *MOTION.lock().unwrap_or_else(|error| error.into_inner()) = Some(observation);
    Ok(())
}
/// Stops local delivery and schedules platform cleanup without blocking the UI.
#[napi]
pub fn demo_stop_motion() {
    MOTION
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .take();
}
