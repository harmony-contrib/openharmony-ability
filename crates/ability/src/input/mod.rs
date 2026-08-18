use std::fmt::Debug;

use ohos_ime_binding::KeyboardStatus;
use ohos_xcomponent_binding::{KeyEventData, MouseEventData, TouchEventData};

mod ime;
mod text_input;
pub(crate) use ime::ime_ts_fn;
pub use text_input::*;

#[derive(Clone)]
pub enum InputEvent {
    KeyEvent(KeyEventData),
    MouseEvent(MouseEventData),
    TouchEvent(TouchEventData),
    ImeEvent(ImeEvent),
}

impl Debug for InputEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InputEvent::KeyEvent(data) => write!(f, "KeyEvent: {:?}", data),
            InputEvent::MouseEvent(data) => write!(f, "MouseEvent: {:?}", data),
            InputEvent::TouchEvent(data) => write!(f, "TouchEvent: {:?}", data),
            InputEvent::ImeEvent(data) => write!(f, "ImeEvent: {:?}", data),
        }
    }
}

#[derive(Clone)]
pub enum ImeEvent {
    TextInputEvent(TextInputEventData),
    BackspaceEvent(i32),
    ImeStatusEvent(KeyboardStatus),
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
    use ohos_xcomponent_binding::{MouseAction, MouseButton};

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
