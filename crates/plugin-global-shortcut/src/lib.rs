//! Asynchronous global shortcut bridge plugin facade.
//!
//! Provides `register`, `unregister`, and `unregister-all` actions through the bridge plugin model.
//! The ArkTS side uses `inputConsumer.on('hotkeyChange', ...)` to interact with the system
//! shortcut manager. Triggered shortcuts are pushed back to Rust via `invokeNativeSync` as
//! `on-shortcut-triggered` main-thread events, decoded here and forwarded through a crossbeam
//! channel for consumer consumption.
//!
//! Version guard: `inputConsumer` hotkey registration requires API 14+. On lower API levels,
//! `register` silently returns `Ok(())`.

use std::sync::OnceLock;

use crossbeam_channel::{unbounded, Receiver, Sender};
use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::Unknown;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, version, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

/// OHOS `inputConsumer.preKeys` supports at most 2 modifier keys.
const MAX_MODIFIERS: usize = 2;

/// Minimum API level for `inputConsumer.on('hotkeyChange')`.
const MIN_HOTKEY_API_VERSION: i32 = 14;

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
}

impl_bridge_napi_type!(
    ShortcutUnregisterRequest,
    "ohos.global-shortcut.UnregisterRequest"
);

// ── unregister-all ────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ShortcutUnregisterAllRequest {}

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

    /// Registers a global shortcut. On API levels below 14, silently returns `Ok(())`.
    ///
    /// The `modifiers` slice uses the cross-platform modifier names:
    /// `"Control"`, `"Shift"`, `"Alt"`, `"Super"`.
    pub async fn register(&self, id: u32, modifiers: &[String], key: &str) -> Result<()> {
        if version::sdk_api_version() < MIN_HOTKEY_API_VERSION {
            return Ok(());
        }
        let deduped = validate_and_dedup_modifiers(modifiers)?;
        let response = self
            .call::<ShortcutRegisterRequest, ShortcutAcknowledgement>(
                "register",
                ShortcutRegisterRequest {
                    id,
                    modifiers: deduped,
                    key: key.to_owned(),
                },
            )
            .await?;
        response.ensure()
    }

    /// Unregisters a previously registered shortcut by ID. Idempotent — unregistering an
    /// unknown ID succeeds silently.
    pub async fn unregister(&self, id: u32) -> Result<()> {
        if version::sdk_api_version() < MIN_HOTKEY_API_VERSION {
            return Ok(());
        }
        let response = self
            .call::<ShortcutUnregisterRequest, ShortcutAcknowledgement>(
                "unregister",
                ShortcutUnregisterRequest { id },
            )
            .await?;
        response.ensure()
    }

    /// Unregisters all previously registered shortcuts.
    pub async fn unregister_all(&self) -> Result<()> {
        if version::sdk_api_version() < MIN_HOTKEY_API_VERSION {
            return Ok(());
        }
        let response = self
            .call::<ShortcutUnregisterAllRequest, ShortcutAcknowledgement>(
                "unregister-all",
                ShortcutUnregisterAllRequest {},
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
