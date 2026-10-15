//! Asynchronous global shortcut bridge plugin facade.
//!
//! Provides `register`, `unregister`, and `unregister-all` actions through the bridge plugin model.
//! The ArkTS side uses `inputConsumer.on('hotkeyChange', ...)` to interact with the system
//! shortcut manager. Triggered shortcuts are pushed back to Rust via `invokeNativeSync` as
//! `on-shortcut-triggered` main-thread events, decoded here and forwarded through a crossbeam
//! channel for consumer consumption.
//!
//! Version guard: `inputConsumer` hotkey registration requires API 14+. On lower API levels,
//! the client methods return an error naming the required API level.
//!
//! ## Registration generations (ghost-hotkey race)
//!
//! Every register / unregister / unregister-all request carries a `generation`:
//! a monotonic sequence number the embedding plugin takes from its global
//! counter at dispatch time. The ArkTS side tracks the highest generation
//! served (a global floor plus a per-id watermark) and rejects any request
//! carrying an older one, so an in-flight `register` that arrives after a
//! later `unregister` / `unregister-all` cannot resurrect a physical
//! registration the Rust side no longer tracks. The rejection surfaces as a
//! normal registration error on the worker, whose cleanup path is a no-op
//! against the already-updated store.

use std::sync::OnceLock;

use crossbeam_channel::{unbounded, Receiver, Sender};
use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::Unknown;
use napi_ohos::{Error, Result};
pub use openharmony_ability::version;
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

/// OHOS `inputConsumer.preKeys` supports at most 2 modifier keys.
const MAX_MODIFIERS: usize = 2;

/// Minimum API level for `inputConsumer.on('hotkeyChange')`.
const MIN_HOTKEY_API_VERSION: i32 = 14;

/// Unified version error for all hotkey operations: names the operation, the
/// required API level, and the current one.
fn hotkey_api_version_error(op: &str) -> Error {
    Error::from_reason(format!(
        "{op} requires API level {MIN_HOTKEY_API_VERSION}+ on OpenHarmony (current: {})",
        version::sdk_api_version()
    ))
}

// ── Bridge plugin declaration ─────────────────────────────────────────────────

pub struct GlobalShortcutBridgePlugin;

impl BridgePlugin for GlobalShortcutBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.global-shortcut";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        match event.name() {
            "on-shortcut-triggered" => {
                let triggered: ShortcutTriggeredEvent = event.decode()?;
                let _ = SHORTCUT_EVENT_CHANNEL
                    .get()
                    .map(|(sender, _)| sender.send(triggered));
                event.respond(true)
            }
            other => Err(Error::from_reason(format!(
                "Unsupported ohos.global-shortcut main-thread event '{other}'"
            ))),
        }
    }
}

// ── Crossbeam event channel ───────────────────────────────────────────────────

static SHORTCUT_EVENT_CHANNEL: OnceLock<(
    Sender<ShortcutTriggeredEvent>,
    Receiver<ShortcutTriggeredEvent>,
)> = OnceLock::new();

fn shortcut_event_channel() -> &'static (
    Sender<ShortcutTriggeredEvent>,
    Receiver<ShortcutTriggeredEvent>,
) {
    SHORTCUT_EVENT_CHANNEL.get_or_init(unbounded)
}

// ── register ──────────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ShortcutRegisterRequest {
    pub id: u32,
    /// Modifier key names: `"Control"`, `"Shift"`, `"Alt"`, `"Super"`.
    /// At least 1 is required; at most 2 are supported (OHOS `inputConsumer.preKeys` limit).
    pub modifiers: Vec<String>,
    /// Key name: `"A"`, `"F5"`, `"Space"`, etc.
    pub key: String,
    /// Registration generation: a monotonic sequence number taken from the
    /// embedding plugin's global counter at dispatch time. The ArkTS side
    /// rejects requests carrying a generation older than the newest one it
    /// has served (see the module docs: ghost-hotkey race).
    pub generation: u32,
}

impl_bridge_napi_type!(
    ShortcutRegisterRequest,
    "ohos.global-shortcut.RegisterRequest"
);

// ── unregister ─────────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ShortcutUnregisterRequest {
    pub id: u32,
    /// Operation generation (see [`ShortcutRegisterRequest::generation`]):
    /// the per-id watermark on the ArkTS side is raised to this value, so
    /// any in-flight register for the same id dispatched earlier (smaller
    /// generation) is rejected on arrival.
    pub generation: u32,
}

impl_bridge_napi_type!(
    ShortcutUnregisterRequest,
    "ohos.global-shortcut.UnregisterRequest"
);

// ── unregister-all ────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ShortcutUnregisterAllRequest {
    /// Sweep generation (see [`ShortcutRegisterRequest::generation`]): the
    /// ArkTS side raises its global generation floor to this value, so any
    /// in-flight register dispatched earlier (smaller generation) is
    /// rejected on arrival instead of resurrecting a hotkey after the
    /// sweep.
    pub generation: u32,
}

impl_bridge_napi_type!(
    ShortcutUnregisterAllRequest,
    "ohos.global-shortcut.UnregisterAllRequest"
);

// ── acknowledgement ───────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ShortcutAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    ShortcutAcknowledgement,
    "ohos.global-shortcut.Acknowledgement"
);

impl ShortcutAcknowledgement {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "Global shortcut plugin rejected the requested operation",
            ))
        }
    }
}

// ── triggered event (ArkTS → Rust reverse event) ──────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ShortcutTriggeredEvent {
    pub id: u32,
    /// `"Pressed"` or `"Released"`.
    pub state: String,
}

impl_bridge_napi_type!(
    ShortcutTriggeredEvent,
    "ohos.global-shortcut.TriggeredEvent"
);

// ── Modifier validation ────────────────────────────────────────────────────────

/// Validates and deduplicates consecutive modifier entries.
///
/// - At least 1 modifier is required (OHOS `inputConsumer.preKeys` must be non-empty).
/// - At most 2 modifiers are supported (OHOS `inputConsumer.preKeys` limit).
/// - Consecutive duplicate modifiers are removed (e.g. `["Control", "Control"]` → `["Control"]`),
///   matching the legacy `dedup()` behavior.
fn validate_and_dedup_modifiers(modifiers: &[String]) -> Result<Vec<String>> {
    if modifiers.is_empty() {
        return Err(Error::from_reason("At least 1 modifier key is required"));
    }
    if modifiers.len() > MAX_MODIFIERS {
        return Err(Error::from_reason(format!(
            "OHOS supports at most {} modifier keys",
            MAX_MODIFIERS
        )));
    }
    let mut unique: Vec<String> = modifiers.to_vec();
    unique.dedup();
    Ok(unique)
}

// ── Client facade ─────────────────────────────────────────────────────────────

/// Worker-safe facade for the system global shortcut manager.
#[derive(Clone)]
pub struct GlobalShortcutClient {
    bridge: BridgeRuntime,
}

impl GlobalShortcutClient {
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
            .call_async::<GlobalShortcutBridgePlugin, Request, Response>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await
    }

    /// Registers a global shortcut. On API levels below 14, returns an error
    /// naming the required API level.
    ///
    /// The `modifiers` slice uses the cross-platform modifier names:
    /// `"Control"`, `"Shift"`, `"Alt"`, `"Super"`.
    ///
    /// `generation` is the operation sequence number taken by the caller at
    /// dispatch time; the ArkTS side rejects it when a newer-generation
    /// unregister / unregister-all has already been served (see the module
    /// docs: ghost-hotkey race), which surfaces here as
    /// [`Error::from_reason`] just like any other rejection.
    pub async fn register(
        &self,
        id: u32,
        modifiers: &[String],
        key: &str,
        generation: u32,
    ) -> Result<()> {
        if version::sdk_api_version() < MIN_HOTKEY_API_VERSION {
            return Err(hotkey_api_version_error("register"));
        }
        let deduped = validate_and_dedup_modifiers(modifiers)?;
        let response = self
            .call::<ShortcutRegisterRequest, ShortcutAcknowledgement>(
                "register",
                ShortcutRegisterRequest {
                    id,
                    modifiers: deduped,
                    key: key.to_owned(),
                    generation,
                },
            )
            .await?;
        response.ensure()
    }

    /// Unregisters a previously registered shortcut by ID. Idempotent — unregistering an
    /// unknown ID succeeds silently. On API levels below 14, returns an error naming
    /// the required API level.
    ///
    /// `generation` raises the per-id watermark on the ArkTS side: an
    /// in-flight register for the same id dispatched before this call
    /// (smaller generation) is rejected when it arrives.
    pub async fn unregister(&self, id: u32, generation: u32) -> Result<()> {
        if version::sdk_api_version() < MIN_HOTKEY_API_VERSION {
            return Err(hotkey_api_version_error("unregister"));
        }
        let response = self
            .call::<ShortcutUnregisterRequest, ShortcutAcknowledgement>(
                "unregister",
                ShortcutUnregisterRequest { id, generation },
            )
            .await?;
        response.ensure()
    }

    /// Unregisters all previously registered shortcuts. On API levels below 14,
    /// returns an error naming the required API level.
    ///
    /// `generation` raises the ArkTS-side global generation floor: any
    /// in-flight register dispatched before this sweep (smaller generation)
    /// is rejected on arrival, so a late register cannot resurrect a hotkey
    /// the Rust side no longer tracks.
    pub async fn unregister_all(&self, generation: u32) -> Result<()> {
        if version::sdk_api_version() < MIN_HOTKEY_API_VERSION {
            return Err(hotkey_api_version_error("unregisterAll"));
        }
        let response = self
            .call::<ShortcutUnregisterAllRequest, ShortcutAcknowledgement>(
                "unregister-all",
                ShortcutUnregisterAllRequest { generation },
            )
            .await?;
        response.ensure()
    }

    /// Returns the crossbeam receiver for shortcut trigger events.
    ///
    /// Each triggered shortcut produces a `ShortcutTriggeredEvent` with `state: "Pressed"`
    /// followed by a synthesized `state: "Released"` event.
    pub fn event_receiver(&self) -> &'static Receiver<ShortcutTriggeredEvent> {
        &shortcut_event_channel().1
    }
}

pub trait GlobalShortcutExt {
    fn global_shortcut(&self) -> Result<GlobalShortcutClient>;
}

impl GlobalShortcutExt for OpenHarmonyApp {
    fn global_shortcut(&self) -> Result<GlobalShortcutClient> {
        GlobalShortcutClient::new(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn global_shortcut_plugin_targets_ability_context() {
        assert_eq!(GlobalShortcutBridgePlugin::ID, "ohos.global-shortcut");
        assert_eq!(
            GlobalShortcutBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }

    #[test]
    fn global_shortcut_types_have_stable_named_napi_contracts() {
        assert_eq!(
            <ShortcutRegisterRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.global-shortcut.RegisterRequest"
        );
        assert_eq!(
            <ShortcutUnregisterRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.global-shortcut.UnregisterRequest"
        );
        assert_eq!(
            <ShortcutUnregisterAllRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.global-shortcut.UnregisterAllRequest"
        );
        assert_eq!(
            <ShortcutAcknowledgement as BridgeNapiType>::TYPE_NAME,
            "ohos.global-shortcut.Acknowledgement"
        );
        assert_eq!(
            <ShortcutTriggeredEvent as BridgeNapiType>::TYPE_NAME,
            "ohos.global-shortcut.TriggeredEvent"
        );
    }

    #[test]
    fn modifier_validation_rejects_empty() {
        assert!(validate_and_dedup_modifiers(&[]).is_err());
    }

    #[test]
    fn modifier_validation_rejects_more_than_two() {
        let mods = vec!["Control".to_owned(), "Shift".to_owned(), "Alt".to_owned()];
        assert!(validate_and_dedup_modifiers(&mods).is_err());
    }

    #[test]
    fn modifier_validation_dedups_consecutive_duplicates() {
        let mods = vec!["Control".to_owned(), "Control".to_owned()];
        let result = validate_and_dedup_modifiers(&mods).unwrap();
        assert_eq!(result, vec!["Control".to_owned()]);
    }

    #[test]
    fn modifier_validation_accepts_two_distinct() {
        let mods = vec!["Control".to_owned(), "Shift".to_owned()];
        let result = validate_and_dedup_modifiers(&mods).unwrap();
        assert_eq!(result, vec!["Control".to_owned(), "Shift".to_owned()]);
    }

    #[test]
    fn modifier_validation_does_not_dedup_non_consecutive() {
        let mods = vec![
            "Control".to_owned(),
            "Shift".to_owned(),
            "Control".to_owned(),
        ];
        assert!(validate_and_dedup_modifiers(&mods).is_err());
    }
}
