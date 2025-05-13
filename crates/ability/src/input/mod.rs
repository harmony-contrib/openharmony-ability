use std::fmt::Debug;

use ohos_ime_binding::KeyboardStatus;
use ohos_xcomponent_binding::{KeyEventData, TouchEventData};

mod ime;
mod text_input;
pub use ime::*;
pub use text_input::*;

#[derive(Clone)]
pub enum InputEvent {
    KeyEvent(KeyEventData),
    TouchEvent(TouchEventData),
    ImeEvent(ImeEvent),
}

impl Debug for InputEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InputEvent::KeyEvent(data) => write!(f, "KeyEvent: {:?}", data),
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
}

impl Debug for ImeEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImeEvent::TextInputEvent(data) => write!(f, "TextInputEvent: {:?}", data),
            ImeEvent::BackspaceEvent(len) => write!(f, "BackspaceEvent: delete length is {}", len),
            ImeEvent::ImeStatusEvent(status) => write!(f, "ImeStatusEvent: {:?}", status),
        }
    }
}
