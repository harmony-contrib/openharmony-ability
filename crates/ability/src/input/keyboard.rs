#[cfg(all(feature = "keyboard", not(feature = "api-19")))]
use ohos_arkui_binding::event::KeyLockState;
#[cfg(feature = "keyboard")]
use ohos_arkui_binding::event::{inner_event::Event, KeyEventType};
#[cfg(feature = "keyboard")]
use ohos_xcomponent_binding::{Action, EventSource, KeyCode};
#[cfg(feature = "keyboard")]
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

/// Selects one keyboard stream; the same physical key is never delivered twice.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum KeyboardInputDelivery {
    /// Raw XComponent key codes, available on older systems.
    #[default]
    RawXComponent,
    /// Every ArkUI physical key once, with its IME disposition (API 14+).
    #[cfg(feature = "keyboard")]
    ArkUi,
}

#[cfg(feature = "keyboard")]
impl KeyboardInputDelivery {
    pub(crate) fn validate_runtime(self, api: i32) -> napi_ohos::Result<()> {
        if self == Self::ArkUi && api < 14 {
            return Err(napi_ohos::Error::from_reason(
                "ArkUI keyboard delivery requires API 14",
            ));
        }
        Ok(())
    }
}

#[cfg(all(test, feature = "keyboard"))]
mod delivery_tests {
    use super::KeyboardInputDelivery;

    #[test]
    fn arkui_keys_use_the_d3_api14_baseline() {
        for api in [0, 12, 13] {
            assert!(KeyboardInputDelivery::ArkUi.validate_runtime(api).is_err());
        }
        for api in [14, 19, 20, 26] {
            assert!(KeyboardInputDelivery::ArkUi.validate_runtime(api).is_ok());
        }
        assert!(KeyboardInputDelivery::RawXComponent
            .validate_runtime(12)
            .is_ok());
    }
}

/// An owned snapshot. Native input pointers never outlive their callback.
#[cfg(feature = "keyboard")]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyboardEventData {
    pub code: KeyCode,
    pub action: Action,
    pub device_id: i64,
    pub source: EventSource,
    pub timestamp: i64,
    /// System character, or zero when the SDK cannot translate this key.
    pub unicode: u32,
    /// `None` means the system query failed, rather than no keys being held.
    pub pressed_keys: Option<Vec<KeyCode>>,
    /// Available with `api-19` (API 19+); otherwise unknown.
    pub caps_lock: Option<bool>,
    pub num_lock: Option<bool>,
    /// The transition was handled before post-IME delivery. Update held-key state,
    /// but do not execute a shortcut or insert hardware text for a consumed key.
    pub ime_consumed: bool,
    /// Consume a post-IME key synchronously before its native callback returns.
    /// Late changes to this owned reply cannot affect a later native key.
    pub response: KeyboardEventResponse,
}

#[cfg(feature = "keyboard")]
#[derive(Clone, Debug, Default)]
pub struct KeyboardEventResponse(Arc<AtomicBool>);

#[cfg(feature = "keyboard")]
impl PartialEq for KeyboardEventResponse {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}
#[cfg(feature = "keyboard")]
impl Eq for KeyboardEventResponse {}

#[cfg(feature = "keyboard")]
impl KeyboardEventResponse {
    pub fn consume(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub(crate) fn is_consumed(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

#[cfg(feature = "keyboard")]
impl KeyboardEventData {
    pub(crate) fn from_node_callback(node_event: &Event) -> Option<Self> {
        let event = node_event.key_event()?;
        let action = match event.event_type() {
            KeyEventType::Down => Action::Down,
            KeyEventType::Up => Action::Up,
            // Long-press/click are semantic events, not additional key transitions.
            _ => return None,
        };
        let mut pressed = [0; 64];
        let mut pressed_keys = event.pressed_keys(&mut pressed).ok().and_then(|length| {
            pressed.get(..length).map(|codes| {
                codes
                    .iter()
                    .map(|code| KeyCode::from(*code as u32))
                    .collect::<Vec<_>>()
            })
        });
        let code = KeyCode::from(event.key_code_raw() as u32);
        if let Some(pressed) = pressed_keys.as_mut() {
            match action {
                Action::Up => pressed.retain(|pressed| *pressed != code),
                Action::Down if !pressed.contains(&code) => pressed.push(code),
                _ => {}
            }
        }
        #[cfg(feature = "api-19")]
        let locks = event.lock_state();
        #[cfg(not(feature = "api-19"))]
        let locks = KeyLockState::default();
        Some(Self {
            code,
            action,
            device_id: event.device_id() as i64,
            // ArkUI and XComponent swap the numeric values for keyboard and joystick.
            source: match u32::from(event.source()) {
                1 => EventSource::Mouse,
                4 => EventSource::Keyboard,
                5 => EventSource::Joystick,
                _ => EventSource::Unknown,
            },
            timestamp: event.event_time(),
            unicode: event.unicode(),
            pressed_keys,
            caps_lock: locks.caps_lock,
            num_lock: locks.num_lock,
            ime_consumed: false,
            response: KeyboardEventResponse::default(),
        })
    }
}
