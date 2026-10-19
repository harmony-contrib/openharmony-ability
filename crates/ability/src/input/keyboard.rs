#[cfg(feature = "keyboard")]
use ohos_arkui_binding::{
    arkui_input_binding::{sys::ArkUI_UIInputEvent, ArkUIInputEvent},
    event::{inner_event::Event, KeyEventType, KeyLockState},
};
#[cfg(feature = "keyboard")]
use ohos_xcomponent_binding::{Action, EventSource, KeyCode};
#[cfg(feature = "keyboard")]
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, OnceLock,
};

/// Selects one keyboard stream; the same physical key is never delivered twice.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum KeyboardInputDelivery {
    /// Raw XComponent key codes, available on older systems.
    #[default]
    RawXComponent,
    /// ArkUI keys not consumed by the IME, including Unicode and held-key state (API 14+).
    #[cfg(feature = "keyboard")]
    ArkUi,
    /// ArkUI delivery for editors that handle all unconsumed hardware text and
    /// function keys. Advertises this capability to the IME on API 26+; older
    /// systems retain ordinary ArkUI delivery.
    #[cfg(feature = "keyboard")]
    ArkUiWithTextInput,
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
    /// Lock queries are optional on systems before API 19.
    pub caps_lock: Option<bool>,
    pub num_lock: Option<bool>,
    /// Consume a pre- or post-IME key synchronously before its native callback returns.
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
        let native_input = node_event.input_event()?;
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
        let locks = KeyLockQueries::state(&native_input);
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
            response: KeyboardEventResponse::default(),
        })
    }
}

#[cfg(feature = "keyboard")]
type KeyLockQuery = unsafe extern "C" fn(*const ArkUI_UIInputEvent, *mut bool) -> u32;

#[cfg(feature = "keyboard")]
struct KeyLockQueries {
    _library: libloading::Library,
    caps_lock: Option<KeyLockQuery>,
    num_lock: Option<KeyLockQuery>,
    scroll_lock: Option<KeyLockQuery>,
}

#[cfg(feature = "keyboard")]
impl KeyLockQueries {
    fn state(event: &ArkUIInputEvent) -> KeyLockState {
        static QUERIES: OnceLock<Option<KeyLockQueries>> = OnceLock::new();
        let Some(queries) = QUERIES.get_or_init(Self::load) else {
            return KeyLockState::default();
        };
        KeyLockState {
            caps_lock: Self::query(queries.caps_lock, event),
            num_lock: Self::query(queries.num_lock, event),
            scroll_lock: Self::query(queries.scroll_lock, event),
        }
    }

    fn load() -> Option<Self> {
        // N-API modules cannot resolve these symbols through the process handle
        // on OHOS. Keep the NDK library open for the optional API-19 queries.
        let library = match unsafe { libloading::Library::new("libace_ndk.z.so") } {
            Ok(library) => library,
            Err(error) => {
                crate::warn!("Cannot load ArkUI keyboard lock queries: {error}");
                return None;
            }
        };
        // SAFETY: native_key_event.h declares all three functions with this
        // signature. Missing symbols on older systems leave the state unknown.
        unsafe {
            Some(Self {
                caps_lock: library
                    .get::<KeyLockQuery>(b"OH_ArkUI_KeyEvent_IsCapsLockOn\0")
                    .ok()
                    .map(|query| *query),
                num_lock: library
                    .get::<KeyLockQuery>(b"OH_ArkUI_KeyEvent_IsNumLockOn\0")
                    .ok()
                    .map(|query| *query),
                scroll_lock: library
                    .get::<KeyLockQuery>(b"OH_ArkUI_KeyEvent_IsScrollLockOn\0")
                    .ok()
                    .map(|query| *query),
                _library: library,
            })
        }
    }

    fn query(query: Option<KeyLockQuery>, event: &ArkUIInputEvent) -> Option<bool> {
        let mut state = false;
        // SAFETY: the input pointer is used only within its native node callback.
        (unsafe { query?(event.raw(), &mut state) } == 0).then_some(state)
    }
}
