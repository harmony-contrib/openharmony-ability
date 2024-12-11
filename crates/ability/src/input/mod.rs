use ohos_xcomponent_binding::{KeyEventData, TouchEventData};

mod text_input;
pub use text_input::*;

pub enum InputEvent {
    KeyEvent(KeyEventData),
    TouchEvent(TouchEventData),
    TextInputEvent(TextInputEventData),
}
