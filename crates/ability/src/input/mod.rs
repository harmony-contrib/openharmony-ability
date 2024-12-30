use std::fmt::Debug;

use ohos_xcomponent_binding::{KeyEventData, TouchEventData};

mod text_input;
pub use text_input::*;

#[derive(Clone)]
pub enum InputEvent {
    KeyEvent(KeyEventData),
    TouchEvent(TouchEventData),
    TextInputEvent(TextInputEventData),
}

impl Debug for InputEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InputEvent::KeyEvent(data) => write!(f, "KeyEvent: {:?}", data),
            InputEvent::TouchEvent(data) => write!(f, "TouchEvent: {:?}", data),
            InputEvent::TextInputEvent(data) => write!(f, "TextInputEvent: {:?}", data),
        }
    }
}
