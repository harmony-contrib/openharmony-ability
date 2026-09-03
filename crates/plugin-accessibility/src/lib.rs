//! Accessibility bridge plugin facade.
//!
//! Provides `get-font-scale`, `is-open-accessibility`, `is-touch-explore-enabled`, and
//! `subscribe-state-change`/`unsubscribe-state-change` actions through the bridge plugin
//! model. The ArkTS side reads `abilityContext.config.fontScale` (no permission) and calls
//! `@kit.AccessibilityKit` `accessibility.*` for screen-reader state; state changes flow back
//! through the `accessibility-state-changed` main-thread event.

use std::sync::{Arc, LazyLock, RwLock};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
    PluginLifecycleEvent,
};

/// Carries the app handle so [`Self::on_lifecycle`] can re-issue bridge calls
/// against the **current** session after an Ability rebuild (the previous
/// session's runtime is released on teardown).
pub struct AccessibilityBridgePlugin {
    app: OpenHarmonyApp,
}

impl AccessibilityBridgePlugin {
    pub fn new(app: &OpenHarmonyApp) -> Self {
        Self { app: app.clone() }
    }

    /// Re-issues the state-change subscription after an Ability session rebuild.
    ///
    /// The process can outlive one Ability instance: on recreation the ArkTS
    /// plugin instance is new (the previous instance removed the system listener
    /// in `onDispose`) while the process-wide Rust setup never runs again, so a
    /// one-shot subscription would silently die with the first session. The
    /// handler slot survives across sessions — when it is empty the app never
    /// subscribed and there is nothing to replay.
    ///
    /// Lifecycle dispatch runs on the NAPI main thread, so the bridge call is
    /// issued from a spawned worker (blocking here could deadlock the TSFN
    /// response loop). The ArkTS side is idempotent, so racing the app's initial
    /// subscribe on the first session is harmless.
    fn replay_subscription_after_session_rebuild(&self) {
        let subscribed = STATE_CHANGE_HANDLER
            .read()
            .map(|slot| slot.is_some())
            .unwrap_or(false);
        if !subscribed {
            return;
        }

        let app = self.app.clone();
        let spawned = std::thread::Builder::new()
            .name("accessibility-resubscribe".to_string())
            .spawn(move || {
                let client = match app.accessibility() {
                    Ok(client) => client,
                    Err(e) => {
                        log::error!(
                            "[accessibility] session rebuild: bridge client unavailable: {}",
                            e.reason
                        );
                        return;
                    }
                };
                if let Err(e) = futures_executor::block_on(client.issue_subscribe()) {
                    log::error!(
                        "[accessibility] session rebuild: state-change resubscribe failed: {}",
                        e.reason
                    );
                }
            });
        if spawned.is_err() {
            log::error!("[accessibility] session rebuild: failed to spawn resubscribe worker");
        }
    }
}

impl BridgePlugin for AccessibilityBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.accessibility";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        match event.name() {
            "accessibility-state-changed" => {
                let state = event.decode::<AccessibilityStateChangedEvent>()?;
                dispatch_state_change(state.enabled);
                event.respond(AccessibilityEventAcknowledgement { accepted: true })
            }
            _ => Err(Error::from_reason(format!(
                "Unsupported ohos.accessibility main-thread event '{}'",
                event.name()
            ))),
        }
    }

    fn on_lifecycle(&self, event: &PluginLifecycleEvent) -> Result<()> {
        if matches!(event, PluginLifecycleEvent::AbilityCreated { .. }) {
            self.replay_subscription_after_session_rebuild();
        }
        Ok(())
    }
}

// ── get-font-scale ───────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct AccessibilityGetFontScaleRequest {}

impl_bridge_napi_type!(
    AccessibilityGetFontScaleRequest,
    "ohos.accessibility.GetFontScaleRequest"
);

// NOTE: field names are snake_case here; `#[napi(object)]` converts them to camelCase
// on the wire (`font_scale` -> `fontScale`), matching the ArkTS interfaces.

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityGetFontScaleResponse {
    pub font_scale: f64,
}

impl_bridge_napi_type!(
    AccessibilityGetFontScaleResponse,
    "ohos.accessibility.GetFontScaleResponse"
);

// ── is-open-accessibility ────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct AccessibilityIsOpenRequest {}

impl_bridge_napi_type!(
    AccessibilityIsOpenRequest,
    "ohos.accessibility.IsOpenAccessibilityRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityIsOpenResponse {
    pub enabled: bool,
}

impl_bridge_napi_type!(
    AccessibilityIsOpenResponse,
    "ohos.accessibility.IsOpenAccessibilityResponse"
);

// ── is-touch-explore-enabled ─────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct AccessibilityIsTouchExploreRequest {}

impl_bridge_napi_type!(
    AccessibilityIsTouchExploreRequest,
    "ohos.accessibility.IsTouchExploreRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityIsTouchExploreResponse {
    pub enabled: bool,
}

impl_bridge_napi_type!(
    AccessibilityIsTouchExploreResponse,
    "ohos.accessibility.IsTouchExploreResponse"
);

// ── subscribe / unsubscribe ──────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct AccessibilitySubscribeRequest {}

impl_bridge_napi_type!(
    AccessibilitySubscribeRequest,
    "ohos.accessibility.SubscribeRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilitySubscribeResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    AccessibilitySubscribeResponse,
    "ohos.accessibility.SubscribeResponse"
);

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct AccessibilityUnsubscribeRequest {}

impl_bridge_napi_type!(
    AccessibilityUnsubscribeRequest,
    "ohos.accessibility.UnsubscribeRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityUnsubscribeResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    AccessibilityUnsubscribeResponse,
    "ohos.accessibility.UnsubscribeResponse"
);

// ── accessibility-state-changed event ────────────────────────────────────────────

/// Payload of the `accessibility-state-changed` main-thread event, pushed from the ArkTS
/// `accessibility.on("screenReaderStateChange")` callback via `invokeNativeSync`.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityStateChangedEvent {
    pub enabled: bool,
}

impl_bridge_napi_type!(
    AccessibilityStateChangedEvent,
    "ohos.accessibility.StateChangedEvent"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityEventAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    AccessibilityEventAcknowledgement,
    "ohos.accessibility.EventAcknowledgement"
);

// ── error mapping ────────────────────────────────────────────────────────────────

/// Structured error surface for accessibility queries.
///
/// The ArkTS plugin re-throws system `BusinessError`s as `code=<n> msg=<...>` strings; the
/// bridge runtime surfaces them as napi `Err` reasons. `AccessibilityError::from_reason`
/// maps error code 201 (permission denied) to [`AccessibilityError::PermissionDenied`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AccessibilityError {
    /// The system denied the query (BusinessError code 201 — `ohos.permission.ACCESSIBILITY`).
    PermissionDenied { code: i32, message: String },
    /// The query itself failed for any other reason.
    Unavailable { code: i32, message: String },
}

/// BusinessError code embedded in ArkTS `throw new Error("... code=<n> msg=<...>")`.
const BRIDGE_ERR_PERMISSION: i32 = 201;

impl AccessibilityError {
    fn from_reason(reason: &str) -> Self {
        let code = extract_code(reason).unwrap_or(0);
        let message = reason.to_string();
        if code == BRIDGE_ERR_PERMISSION {
            Self::PermissionDenied { code, message }
        } else {
            Self::Unavailable { code, message }
        }
    }
}

impl std::fmt::Display for AccessibilityError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PermissionDenied { code, message } => {
                write!(f, "accessibility permission denied (code={code}): {message}")
            }
            Self::Unavailable { code, message } => {
                write!(f, "accessibility query failed (code={code}): {message}")
            }
        }
    }
}

impl From<AccessibilityError> for Error {
    fn from(err: AccessibilityError) -> Self {
        Error::from_reason(err.to_string())
    }
}

/// Extracts `code=<n>` from a bridge error reason, if present.
fn extract_code(reason: &str) -> Option<i32> {
    let idx = reason.find("code=")?;
    let rest = &reason[idx + "code=".len()..];
    let digits: String = rest
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '-')
        .collect();
    digits.parse().ok()
}

// ── state-change dispatch ────────────────────────────────────────────────────────

type StateChangeHandler = Arc<dyn Fn(bool) + Send + Sync + 'static>;

static STATE_CHANGE_HANDLER: LazyLock<RwLock<Option<StateChangeHandler>>> =
    LazyLock::new(|| RwLock::new(None));

/// Invoked on the NAPI main thread from `on_main_thread_event`; forwards the state to the
/// registered handler without blocking (the handler must not call back into the bridge
/// synchronously).
fn dispatch_state_change(enabled: bool) {
    let handler = STATE_CHANGE_HANDLER
        .read()
        .ok()
        .and_then(|guard| guard.clone());
    if let Some(handler) = handler {
        handler(enabled);
    }
}

// ── client ───────────────────────────────────────────────────────────────────────

/// Worker-safe facade for accessibility state queries.
#[derive(Clone)]
pub struct AccessibilityClient {
    bridge: BridgeRuntime,
}

impl AccessibilityClient {
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
            .call_async::<AccessibilityBridgePlugin, Request, Response>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await
    }

    /// Returns the system font scale from the ability `Configuration` (default 1.0).
    /// Requires no permission.
    pub async fn get_font_scale(&self) -> Result<f64> {
        let response = self
            .call::<AccessibilityGetFontScaleRequest, AccessibilityGetFontScaleResponse>(
                "get-font-scale",
                AccessibilityGetFontScaleRequest {},
            )
            .await
            .map_err(|e| Error::from(AccessibilityError::from_reason(&e.reason)))?;
        Ok(response.font_scale)
    }

    /// Returns whether a screen reader is currently open.
    ///
    /// OHOS documents `ohos.permission.ACCESSIBILITY` (system_core) for this query; a
    /// third-party denial surfaces as `AccessibilityError::PermissionDenied` rather than
    /// a silent `false`.
    pub async fn is_open_accessibility(&self) -> Result<bool> {
        let response = self
            .call::<AccessibilityIsOpenRequest, AccessibilityIsOpenResponse>(
                "is-open-accessibility",
                AccessibilityIsOpenRequest {},
            )
            .await
            .map_err(|e| Error::from(AccessibilityError::from_reason(&e.reason)))?;
        Ok(response.enabled)
    }

    /// Returns whether touch exploration (touch guide) is enabled.
    pub async fn is_touch_explore_enabled(&self) -> Result<bool> {
        let response = self
            .call::<AccessibilityIsTouchExploreRequest, AccessibilityIsTouchExploreResponse>(
                "is-touch-explore-enabled",
                AccessibilityIsTouchExploreRequest {},
            )
            .await
            .map_err(|e| Error::from(AccessibilityError::from_reason(&e.reason)))?;
        Ok(response.enabled)
    }

    /// Subscribes to screen-reader state changes.
    ///
    /// `handler` runs on the NAPI main thread; keep it cheap (emit into a channel) —
    /// never call back into the bridge or block from inside it. Re-subscribing replaces
    /// the previous handler (the ArkTS side is idempotent).
    pub async fn subscribe_state_change<F>(&self, handler: F) -> Result<()>
    where
        F: Fn(bool) + Send + Sync + 'static,
    {
        // Annotate through the trait-object alias so Arc::clone/ptr_eq below
        // operate on the slot's type (Arc<F> would not coerce at those call sites).
        let handler: StateChangeHandler = Arc::new(handler);
        {
            let mut slot = STATE_CHANGE_HANDLER
                .write()
                .map_err(|_| Error::from_reason("accessibility state-change lock poisoned"))?;
            *slot = Some(Arc::clone(&handler));
        }
        match self.issue_subscribe().await {
            Ok(response) if response.accepted => Ok(()),
            Ok(_) => Err(Error::from_reason(
                "Accessibility plugin rejected subscribe-state-change",
            )),
            Err(e) => {
                // On failure drop the handler again — a stale slot would receive
                // events from a subscription that never completed. Only clear it
                // while the slot still holds OUR handler: a later subscribe may
                // have already replaced it, and clearing that one would silently
                // kill a live subscription.
                if let Ok(mut slot) = STATE_CHANGE_HANDLER.write() {
                    if slot
                        .as_ref()
                        .is_some_and(|current| Arc::ptr_eq(current, &handler))
                    {
                        *slot = None;
                    }
                }
                Err(Error::from(AccessibilityError::from_reason(&e.reason)))
            }
        }
    }

    /// Issues the `subscribe-state-change` bridge call without touching the
    /// registered handler slot. The ArkTS side is idempotent, so this is also
    /// the session-rebuild replay path — the handler survives across sessions
    /// and must not be replaced or cleared by a replay.
    async fn issue_subscribe(&self) -> Result<AccessibilitySubscribeResponse> {
        self.call::<AccessibilitySubscribeRequest, AccessibilitySubscribeResponse>(
            "subscribe-state-change",
            AccessibilitySubscribeRequest {},
        )
        .await
    }

    /// Unsubscribes from screen-reader state changes and drops the handler.
    pub async fn unsubscribe_state_change(&self) -> Result<()> {
        {
            let mut slot = STATE_CHANGE_HANDLER
                .write()
                .map_err(|_| Error::from_reason("accessibility state-change lock poisoned"))?;
            *slot = None;
        }
        let response = self
            .call::<AccessibilityUnsubscribeRequest, AccessibilityUnsubscribeResponse>(
                "unsubscribe-state-change",
                AccessibilityUnsubscribeRequest {},
            )
            .await
            .map_err(|e| Error::from(AccessibilityError::from_reason(&e.reason)))?;
        if response.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "Accessibility plugin rejected unsubscribe-state-change",
            ))
        }
    }
}

pub trait AccessibilityExt {
    fn accessibility(&self) -> Result<AccessibilityClient>;
}

impl AccessibilityExt for OpenHarmonyApp {
    fn accessibility(&self) -> Result<AccessibilityClient> {
        AccessibilityClient::new(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accessibility_plugin_targets_ability_context() {
        assert_eq!(AccessibilityBridgePlugin::ID, "ohos.accessibility");
        assert_eq!(
            AccessibilityBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }

    #[test]
    fn accessibility_types_have_stable_named_napi_contracts() {
        assert_eq!(
            <AccessibilityGetFontScaleRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.accessibility.GetFontScaleRequest"
        );
        assert_eq!(
            <AccessibilityGetFontScaleResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.accessibility.GetFontScaleResponse"
        );
        assert_eq!(
            <AccessibilityIsOpenRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.accessibility.IsOpenAccessibilityRequest"
        );
        assert_eq!(
            <AccessibilityIsOpenResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.accessibility.IsOpenAccessibilityResponse"
        );
        assert_eq!(
            <AccessibilityIsTouchExploreRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.accessibility.IsTouchExploreRequest"
        );
        assert_eq!(
            <AccessibilityIsTouchExploreResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.accessibility.IsTouchExploreResponse"
        );
        assert_eq!(
            <AccessibilityStateChangedEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.accessibility.StateChangedEvent"
        );
        assert_eq!(
            <AccessibilityEventAcknowledgement as BridgeNapiType>::TYPE_NAME,
            "ohos.accessibility.EventAcknowledgement"
        );
    }

    #[test]
    fn error_reason_maps_permission_code() {
        let err = AccessibilityError::from_reason(
            "isScreenReaderOpenSync failed: code=201 msg=permission denied",
        );
        assert_eq!(
            err,
            AccessibilityError::PermissionDenied {
                code: 201,
                message: "isScreenReaderOpenSync failed: code=201 msg=permission denied"
                    .to_string()
            }
        );

        let err = AccessibilityError::from_reason(
            "on(screenReaderStateChange) failed: code=9300001 msg=inner error",
        );
        assert!(matches!(err, AccessibilityError::Unavailable { code: 9300001, .. }));
    }

    #[test]
    fn extract_code_handles_missing_and_negative() {
        assert_eq!(extract_code("no code here"), None);
        assert_eq!(extract_code("failed: code=-1 msg=x"), Some(-1));
        assert_eq!(extract_code("code=201"), Some(201));
    }
}
