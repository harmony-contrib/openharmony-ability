#[cfg(feature = "keyboard")]
use ohos_arkui_binding::event::{KeyEvent, KeyEventType};
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
    /// ArkUI keys not consumed by the IME, including Unicode, held keys and lock state (API 19+).
    #[cfg(feature = "keyboard")]
    ArkUi,
}

#[cfg(feature = "keyboard")]
impl KeyboardInputDelivery {
    pub(crate) fn validate_runtime(self, api_version: i32) -> napi_ohos::Result<()> {
        if self == Self::ArkUi && api_version < 19 {
            return Err(napi_ohos::Error::from_reason(
                "ArkUI keyboard delivery requires API 19",
            ));
        }
        Ok(())
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
    /// `None` means the native lock-state query failed.
    pub caps_lock: Option<bool>,
    pub num_lock: Option<bool>,
    /// Consume a post-IME key synchronously before its native callback returns.
    /// Late changes to this owned reply cannot affect a later native key.
    pub response: KeyboardEventResponse,
}

#[cfg(all(test, feature = "keyboard"))]
mod tests {
    use super::KeyboardInputDelivery;

    #[test]
    fn arkui_keyboard_requires_api_19() {
        for api_version in [0, 12, 14, 18] {
            let error = KeyboardInputDelivery::ArkUi
                .validate_runtime(api_version)
                .unwrap_err();
            assert_eq!(error.reason, "ArkUI keyboard delivery requires API 19");
        }
        for api_version in [19, 20, 26] {
            assert!(KeyboardInputDelivery::ArkUi
                .validate_runtime(api_version)
                .is_ok());
        }
    }

    #[test]
    fn raw_keyboard_keeps_its_existing_baseline() {
        for api_version in [0, 12, 14, 18, 19, 26] {
            assert!(KeyboardInputDelivery::RawXComponent
                .validate_runtime(api_version)
                .is_ok());
        }
    }
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
    pub(crate) fn from_key_callback(event: &KeyEvent<'_>) -> Option<Self> {
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
        let locks = event.lock_state();
        Some(Self {
            code,
            action,
            device_id: event.device_id() as i64,
            source: EventSource::from(u32::from(event.source())),
            timestamp: event.event_time(),
            unicode: event.unicode(),
            pressed_keys,
            caps_lock: locks.caps_lock,
            num_lock: locks.num_lock,
            response: KeyboardEventResponse::default(),
        })
    }
}
