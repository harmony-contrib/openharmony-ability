use std::fmt::Debug;

use ohos_ime_binding::KeyboardStatus;
use ohos_xcomponent_binding::{KeyEventData, TouchEventData};

mod ime;
mod mouse_event;
mod text_input;
pub use ime::*;
pub use mouse_event::*;
pub use text_input::*;

#[derive(Clone)]
/// An input event delivered from the ArkTS/XComponent layer.
pub enum InputEvent {
    /// Physical key press/release (XComponent key event data).
    KeyEvent(KeyEventData),
    /// Mouse press/release/move/hover (synthesized from the NDK mouse event).
    MouseEvent(MouseEventData),
    /// Touch press/move/release on the XComponent surface.
    TouchEvent(TouchEventData),
    /// Axis scroll event (wheel/touchpad).
    AxisEvent(AxisEventData),
    /// IME composition/keyboard-status event.
    ImeEvent(ImeEvent),
}

impl Debug for InputEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InputEvent::KeyEvent(data) => write!(f, "KeyEvent: {:?}", data),
            InputEvent::MouseEvent(data) => write!(f, "MouseEvent: {:?}", data),
            InputEvent::TouchEvent(data) => write!(f, "TouchEvent: {:?}", data),
            InputEvent::AxisEvent(data) => write!(f, "AxisEvent: {:?}", data),
            InputEvent::ImeEvent(data) => write!(f, "ImeEvent: {:?}", data),
        }
    }
}

#[derive(Clone)]
/// An IME (input method) event forwarded from the OHOS input method framework.
pub enum ImeEvent {
    /// Text input notification (inserted/committed text payload).
    TextInputEvent(TextInputEventData),
    /// Backspace pressed; carries the deletion length.
    BackspaceEvent(i32),
    /// Keyboard show/hide status changed; carries the new `KeyboardStatus`.
    ImeStatusEvent(KeyboardStatus),
    /// Enter key pressed; carries the enter key code.
    EnterEvent(i32),
}

impl Debug for ImeEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImeEvent::TextInputEvent(data) => write!(f, "TextInputEvent: {:?}", data),
            ImeEvent::BackspaceEvent(len) => write!(f, "BackspaceEvent: delete length is {}", len),
            ImeEvent::ImeStatusEvent(status) => write!(f, "ImeStatusEvent: {:?}", status),
            ImeEvent::EnterEvent(key) => write!(f, "EnterEvent: {:?}", key),
        }
    }
}

#[cfg(test)]
mod tests {
    use ohos_xcomponent_binding::MouseButton;

    use super::*;

    #[test]
    fn mouse_event_debug_output_includes_event_data() {
        let event = InputEvent::MouseEvent(MouseEventData {
            x: 12.5,
            y: 24.0,
            screen_x: 112.5,
            screen_y: 224.0,
            timestamp: 42,
            action: MouseAction::Move,
            button: MouseButton::NoneButton,
        });

        let output = format!("{event:?}");
        assert!(output.starts_with("MouseEvent: MouseEventData"));
        assert!(output.contains("action: Move"));
        assert!(output.contains("button: NoneButton"));
    }
}
