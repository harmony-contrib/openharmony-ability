//! Observation facade. Platform subscription and lifecycle work stays in ArkTS.

use std::sync::Arc;

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{impl_bridge_napi_type, OpenHarmonyApp};

use super::{
    events::require_accepted, motion_routes::MotionRegistration, AccessibilityBridgePlugin,
    AccessibilityClient, AccessibilityEventAcknowledgement, AccessibilityExt,
};

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityMotionRequest {
    pub id: String,
}
impl_bridge_napi_type!(
    AccessibilityMotionRequest,
    "ohos.accessibility.MotionRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityMotionState {
    pub id: String,
    pub enabled: bool,
}
impl_bridge_napi_type!(AccessibilityMotionState, "ohos.accessibility.MotionState");

/// Owns delivery on the N-API main thread. Drop immediately retires the Rust route.
///
/// A callback already in progress may finish. Drop never calls the platform or schedules
/// cleanup: ArkTS prunes the route on its next notification/context update, or on disposal.
/// Use [`Self::close`] when the platform listener must be removed promptly.
pub struct AccessibilityMotionObservation {
    registration: MotionRegistration,
    app: OpenHarmonyApp,
}

impl AccessibilityMotionObservation {
    /// Retires delivery and awaits platform unsubscribe using the current Ability session.
    /// Errors are reported; disposal still releases that session's system callback.
    pub async fn close(self) -> Result<()> {
        self.registration.retire();
        self.app
            .accessibility()?
            .motion_call("stop-observing-reduce-motion", self.registration.id.clone())
            .await
    }
}

impl AccessibilityClient {
    /// Observes the initial system value and changes (API 23+).
    ///
    /// Keep the callback cheap: it runs synchronously on the N-API main thread and must not
    /// block or reenter the bridge. Retain the returned owner for as long as delivery is needed.
    pub async fn observe_reduce_motion<F>(
        &self,
        handler: F,
    ) -> Result<AccessibilityMotionObservation>
    where
        F: Fn(bool) + Send + Sync + 'static,
    {
        let plugin = self.plugin()?;
        let registration = plugin
            .motion
            .register(Arc::new(handler))
            .map_err(Error::from_reason)?;
        let observation = AccessibilityMotionObservation {
            registration,
            app: self.app.clone(),
        };
        self.motion_call("observe-reduce-motion", observation.registration.id.clone())
            .await?;
        Ok(observation)
    }

    async fn motion_call(&self, action: &str, id: String) -> Result<()> {
        let response: AccessibilityEventAcknowledgement =
            self.call(action, AccessibilityMotionRequest { id }).await?;
        require_accepted(response, "motion observation")
    }

    pub(crate) fn plugin(&self) -> Result<Arc<AccessibilityBridgePlugin>> {
        self.app
            .registered_plugin::<AccessibilityBridgePlugin>()?
            .ok_or_else(|| Error::from_reason("accessibility plugin is not registered"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn stable_contracts() {
        assert_eq!(
            AccessibilityMotionRequest::TYPE_NAME,
            "ohos.accessibility.MotionRequest"
        );
        assert_eq!(
            AccessibilityMotionState::TYPE_NAME,
            "ohos.accessibility.MotionState"
        );
    }
}
