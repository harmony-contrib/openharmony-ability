use std::fmt::Debug;

use ohos_arkui_binding::arkui_input_binding::{UIInputAction, UIInputSourceType, UIInputToolType};
use ohos_ime_binding::KeyboardStatus;
use ohos_xcomponent_binding::{KeyEventData, MouseEventData, TouchEventData};

mod ime;
mod text_input;
pub use ime::*;
pub use text_input::*;

#[derive(Clone)]
pub enum InputEvent {
    KeyEvent(KeyEventData),
    MouseEvent(MouseEventData),
    TouchEvent(TouchEventData),
    AxisEvent(AxisEventData),
    GestureEvent(GestureEvent),
    ImeEvent(ImeEvent),
}

impl Debug for InputEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InputEvent::KeyEvent(data) => write!(f, "KeyEvent: {:?}", data),
            InputEvent::MouseEvent(data) => write!(f, "MouseEvent: {:?}", data),
            InputEvent::TouchEvent(data) => write!(f, "TouchEvent: {:?}", data),
            InputEvent::AxisEvent(data) => write!(f, "AxisEvent: {:?}", data),
            InputEvent::GestureEvent(data) => write!(f, "GestureEvent: {:?}", data),
            InputEvent::ImeEvent(data) => write!(f, "ImeEvent: {:?}", data),
        }
    }
}

/// Owned mouse-wheel, touchpad, or rotary-axis scroll data.
///
/// The underlying ArkUI input object is only valid during the native callback, so the framework
/// snapshots its useful values before delivering the event to the application.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AxisEventData {
    pub delta_x: f64,
    pub delta_y: f64,
    pub timestamp: i64,
    pub action: UIInputAction,
    pub source_type: UIInputSourceType,
    pub tool_type: UIInputToolType,
}

/// System-recognized gestures emitted in parallel with the raw XComponent input stream.
///
/// Consumers can use [`GestureEvent::Tap`] as a semantic click, [`GestureEvent::Pan`] as a
/// scroll-ready stream, and [`GestureEvent::Swipe`] to seed fling or momentum behavior. ArkUI,
/// rather than each rendering framework, owns gesture recognition and threshold handling.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum GestureEvent {
    Tap,
    Pan(PanGestureEvent),
    Swipe(SwipeGestureEvent),
}

/// Lifecycle phase of a continuous system gesture.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GesturePhase {
    Start,
    Update,
    End,
    Cancel,
}

/// Scroll-ready data produced by ArkUI's pan recognizer.
///
/// `offset_*` is the system-provided cumulative displacement. `delta_*` is the displacement
/// since the previous callback, calculated here so downstream frameworks do not need to retain
/// their own XComponent scroll state. Velocity is supplied directly by ArkUI.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PanGestureEvent {
    pub phase: GesturePhase,
    pub delta_x: f32,
    pub delta_y: f32,
    pub offset_x: f32,
    pub offset_y: f32,
    pub velocity: f32,
    pub velocity_x: f32,
    pub velocity_y: f32,
}

/// Fast-swipe data supplied by ArkUI for fling or momentum handling.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SwipeGestureEvent {
    pub phase: GesturePhase,
    pub angle: f32,
    pub velocity: f32,
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

    #[test]
    fn gesture_event_debug_output_includes_scroll_delta() {
        let event = InputEvent::GestureEvent(GestureEvent::Pan(PanGestureEvent {
            phase: GesturePhase::Update,
            delta_x: 2.0,
            delta_y: -4.0,
            offset_x: 12.0,
            offset_y: 24.0,
            velocity: 6.0,
            velocity_x: 3.0,
            velocity_y: -5.0,
        }));

        let output = format!("{event:?}");
        assert!(output.starts_with("GestureEvent: Pan(PanGestureEvent"));
        assert!(output.contains("phase: Update"));
        assert!(output.contains("delta_y: -4.0"));
    }
}
