// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! Data types for the OHOS global shortcut bridge.
//!
//! Defines `Modifier`, `Key`, `ShortcutState`, and `ShortcutEvent` types
//! used for registering/unregistering shortcuts and receiving events.

use serde::{Deserialize, Serialize};

/// Keyboard modifier keys.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Modifier {
    Control,
    Shift,
    Alt,
    /// Super / Meta / Windows / Command key
    Super,
}

impl Modifier {
    /// Returns the string name of the modifier.
    #[cfg(test)]
    pub fn as_str(&self) -> &'static str {
        match self {
            Modifier::Control => "Ctrl",
            Modifier::Shift => "Shift",
            Modifier::Alt => "Alt",
            Modifier::Super => "Meta",
        }
    }
}

/// Common keyboard keys for shortcut registration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Key {
    // Letters
    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,
    // Digits
    Digit0,
    Digit1,
    Digit2,
    Digit3,
    Digit4,
    Digit5,
    Digit6,
    Digit7,
    Digit8,
    Digit9,
    // Function keys
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    F13,
    F14,
    F15,
    F16,
    F17,
    F18,
    F19,
    F20,
    F21,
    F22,
    F23,
    F24,
    // Special keys
    Space,
    Enter,
    Escape,
    Tab,
    Backspace,
    Delete,
    Insert,
    Home,
    End,
    PageUp,
    PageDown,
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
}

impl Key {
    /// Returns the string name of the key.
    #[cfg(test)]
    pub fn as_str(&self) -> &'static str {
        match self {
            Key::A => "A",
            Key::B => "B",
            Key::C => "C",
            Key::D => "D",
            Key::E => "E",
            Key::F => "F",
            Key::G => "G",
            Key::H => "H",
            Key::I => "I",
            Key::J => "J",
            Key::K => "K",
            Key::L => "L",
            Key::M => "M",
            Key::N => "N",
            Key::O => "O",
            Key::P => "P",
            Key::Q => "Q",
            Key::R => "R",
            Key::S => "S",
            Key::T => "T",
            Key::U => "U",
            Key::V => "V",
            Key::W => "W",
            Key::X => "X",
            Key::Y => "Y",
            Key::Z => "Z",
            Key::Digit0 => "0",
            Key::Digit1 => "1",
            Key::Digit2 => "2",
            Key::Digit3 => "3",
            Key::Digit4 => "4",
            Key::Digit5 => "5",
            Key::Digit6 => "6",
            Key::Digit7 => "7",
            Key::Digit8 => "8",
            Key::Digit9 => "9",
            Key::F1 => "F1",
            Key::F2 => "F2",
            Key::F3 => "F3",
            Key::F4 => "F4",
            Key::F5 => "F5",
            Key::F6 => "F6",
            Key::F7 => "F7",
            Key::F8 => "F8",
            Key::F9 => "F9",
            Key::F10 => "F10",
            Key::F11 => "F11",
            Key::F12 => "F12",
            Key::F13 => "F13",
            Key::F14 => "F14",
            Key::F15 => "F15",
            Key::F16 => "F16",
            Key::F17 => "F17",
            Key::F18 => "F18",
            Key::F19 => "F19",
            Key::F20 => "F20",
            Key::F21 => "F21",
            Key::F22 => "F22",
            Key::F23 => "F23",
            Key::F24 => "F24",
            Key::Space => "Space",
            Key::Enter => "Enter",
            Key::Escape => "Escape",
            Key::Tab => "Tab",
            Key::Backspace => "Backspace",
            Key::Delete => "Delete",
            Key::Insert => "Insert",
            Key::Home => "Home",
            Key::End => "End",
            Key::PageUp => "PageUp",
            Key::PageDown => "PageDown",
            Key::ArrowUp => "ArrowUp",
            Key::ArrowDown => "ArrowDown",
            Key::ArrowLeft => "ArrowLeft",
            Key::ArrowRight => "ArrowRight",
        }
    }

    /// Parse a key name string into a `Key` variant.
    /// Accepts the same names as `as_str()` returns.
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "A" => Some(Key::A),
            "B" => Some(Key::B),
            "C" => Some(Key::C),
            "D" => Some(Key::D),
            "E" => Some(Key::E),
            "F" => Some(Key::F),
            "G" => Some(Key::G),
            "H" => Some(Key::H),
            "I" => Some(Key::I),
            "J" => Some(Key::J),
            "K" => Some(Key::K),
            "L" => Some(Key::L),
            "M" => Some(Key::M),
            "N" => Some(Key::N),
            "O" => Some(Key::O),
            "P" => Some(Key::P),
            "Q" => Some(Key::Q),
            "R" => Some(Key::R),
            "S" => Some(Key::S),
            "T" => Some(Key::T),
            "U" => Some(Key::U),
            "V" => Some(Key::V),
            "W" => Some(Key::W),
            "X" => Some(Key::X),
            "Y" => Some(Key::Y),
            "Z" => Some(Key::Z),
            "0" => Some(Key::Digit0),
            "1" => Some(Key::Digit1),
            "2" => Some(Key::Digit2),
            "3" => Some(Key::Digit3),
            "4" => Some(Key::Digit4),
            "5" => Some(Key::Digit5),
            "6" => Some(Key::Digit6),
            "7" => Some(Key::Digit7),
            "8" => Some(Key::Digit8),
            "9" => Some(Key::Digit9),
            "F1" => Some(Key::F1),
            "F2" => Some(Key::F2),
            "F3" => Some(Key::F3),
            "F4" => Some(Key::F4),
            "F5" => Some(Key::F5),
            "F6" => Some(Key::F6),
            "F7" => Some(Key::F7),
            "F8" => Some(Key::F8),
            "F9" => Some(Key::F9),
            "F10" => Some(Key::F10),
            "F11" => Some(Key::F11),
            "F12" => Some(Key::F12),
            "F13" => Some(Key::F13),
            "F14" => Some(Key::F14),
            "F15" => Some(Key::F15),
            "F16" => Some(Key::F16),
            "F17" => Some(Key::F17),
            "F18" => Some(Key::F18),
            "F19" => Some(Key::F19),
            "F20" => Some(Key::F20),
            "F21" => Some(Key::F21),
            "F22" => Some(Key::F22),
            "F23" => Some(Key::F23),
            "F24" => Some(Key::F24),
            "Space" => Some(Key::Space),
            "Enter" => Some(Key::Enter),
            "Escape" => Some(Key::Escape),
            "Tab" => Some(Key::Tab),
            "Backspace" => Some(Key::Backspace),
            "Delete" => Some(Key::Delete),
            "Insert" => Some(Key::Insert),
            "Home" => Some(Key::Home),
            "End" => Some(Key::End),
            "PageUp" => Some(Key::PageUp),
            "PageDown" => Some(Key::PageDown),
            "ArrowUp" => Some(Key::ArrowUp),
            "ArrowDown" => Some(Key::ArrowDown),
            "ArrowLeft" => Some(Key::ArrowLeft),
            "ArrowRight" => Some(Key::ArrowRight),
            _ => None,
        }
    }
}

/// State of a shortcut event — matches the desktop hotkey crate's `HotKeyState`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ShortcutState {
    Pressed,
    Released,
}

/// A shortcut event received from the OHOS `inputConsumer` bridge.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShortcutEvent {
    /// The unique ID of the registered shortcut that was triggered.
    pub id: u32,
    /// Whether the key was pressed or released.
    pub state: ShortcutState,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modifier_serialization() {
        let m = Modifier::Control;
        let json = serde_json::to_string(&m).unwrap();
        assert_eq!(json, r#""Control""#);
        let deserialized: Modifier = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized, Modifier::Control);
    }

    #[test]
    fn key_serialization() {
        let k = Key::F5;
        let json = serde_json::to_string(&k).unwrap();
        assert_eq!(json, r#""F5""#);
        let deserialized: Key = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized, Key::F5);
    }

    #[test]
    fn shortcut_event_serialization() {
        let event = ShortcutEvent {
            id: 42,
            state: ShortcutState::Pressed,
        };
        let json = serde_json::to_string(&event).unwrap();
        let deserialized: ShortcutEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.id, 42);
        assert_eq!(deserialized.state, ShortcutState::Pressed);
    }

    #[test]
    fn modifier_as_str() {
        assert_eq!(Modifier::Control.as_str(), "Ctrl");
        assert_eq!(Modifier::Shift.as_str(), "Shift");
        assert_eq!(Modifier::Alt.as_str(), "Alt");
        assert_eq!(Modifier::Super.as_str(), "Meta");
    }

    #[test]
    fn key_as_str() {
        assert_eq!(Key::A.as_str(), "A");
        assert_eq!(Key::F5.as_str(), "F5");
        assert_eq!(Key::Space.as_str(), "Space");
        assert_eq!(Key::Escape.as_str(), "Escape");
    }

    #[test]
    fn shortcut_state_variants() {
        let pressed = ShortcutState::Pressed;
        let released = ShortcutState::Released;
        assert_ne!(pressed, released);
        let json_p = serde_json::to_string(&pressed).unwrap();
        let json_r = serde_json::to_string(&released).unwrap();
        assert_eq!(json_p, r#""Pressed""#);
        assert_eq!(json_r, r#""Released""#);
    }
}
