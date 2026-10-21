use std::fmt::Debug;

use ohos_arkui_binding::{
    arkui_input_binding::{
        ArkUIInputEvent, UIInputAction, UIInputEvent, UIInputSourceType, UIInputToolType,
    },
    gesture::gesture_data::GestureInputData,
};
use ohos_ime_binding::{Action, Direction, KeyboardStatus};
use ohos_xcomponent_binding::{KeyEventData, MouseEventData, TouchEventData};

#[cfg(feature = "drag")]
pub(crate) mod drag;
mod ime;
pub(crate) mod queue;
#[cfg(feature = "drag")]
pub use drag::{
    DragInputData, DragOperation, DragPhase, DragPreview, DragResponse, NativeDragResult,
    NativeFileDrag,
};
mod keyboard;
mod text_input;
pub(crate) use ime::*;
#[cfg(feature = "keyboard")]
pub use keyboard::KeyboardEventData;
pub use keyboard::KeyboardInputDelivery;
pub use text_input::*;

#[derive(Clone)]
pub enum InputEvent {
    XComponent(XComponentInputEvent),
    ArkUi(ArkUiInputEvent),
    Ime(ImeEvent),
}

impl Debug for InputEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InputEvent::XComponent(data) => write!(f, "XComponent: {data:?}"),
            InputEvent::ArkUi(data) => write!(f, "ArkUi: {data:?}"),
            InputEvent::Ime(data) => write!(f, "Ime: {data:?}"),
        }
    }
}

/// Raw input delivered by the native XComponent callback APIs.
#[derive(Clone, Debug)]
pub enum XComponentInputEvent {
    Key(KeyEventData),
    Mouse(MouseEventData),
    Hover(bool),
    Touch(TouchEventData),
}

/// Owned ArkUI input and gesture semantics attached to the XComponent node.
#[derive(Clone, Debug, PartialEq)]
pub enum ArkUiInputEvent {
    /// Keyboard focus of the render node, independent of the containing window.
    FocusChanged(bool),
    /// Pointer identity only; the existing XComponent callback delivers the input itself.
    Pointer(PointerInputData),
    #[cfg(feature = "drag")]
    Drag(DragInputData),
    /// One physical transition, including keys consumed by the IME.
    #[cfg(feature = "keyboard")]
    Key(KeyboardEventData),
    Axis(AxisEventData),
    Gesture(GestureEvent),
}

/// Controls which touch representation is delivered to the application.
///
/// Mouse input remains XComponent events, while wheel and touchpad axis input remains an
/// ArkUI event regardless of this setting. Configure delivery before the first render starts.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum TouchInputDelivery {
    /// Deliver only raw XComponent touch events.
    #[default]
    RawXComponent,
    /// Deliver only system-recognized ArkUI tap, pan, and swipe gestures.
    ArkUiGestures,
    /// Deliver both representations of the same physical touch stream.
    Both,
}

impl TouchInputDelivery {
    pub(crate) fn delivers_raw_touch(self) -> bool {
        matches!(self, Self::RawXComponent | Self::Both)
    }

    pub(crate) fn delivers_arkui_gestures(self) -> bool {
        matches!(self, Self::ArkUiGestures | Self::Both)
    }
}

/// Owned pointer metadata captured while an ArkUI callback's raw input is valid.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PointerInputData {
    pub event_type: UIInputEvent,
    pub action: UIInputAction,
    pub source_type: UIInputSourceType,
    pub tool_type: UIInputToolType,
    pub x: f32,
    pub y: f32,
    pub window_x: f32,
    pub window_y: f32,
    pub display_x: f32,
    pub display_y: f32,
    pub timestamp: i64,
    pub pointer_count: u32,
    pub pointer_id: Option<i32>,
    /// Current native mouse button state; absent for non-mouse or unavailable snapshots.
    pub mouse_buttons_pressed: Option<bool>,
    /// Pen pose copied while the native input event is alive.
    pub stylus: Option<StylusInputData>,
}

/// Native pen pose in degrees, with normalized pressure. Missing values stay unknown.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StylusInputData {
    pub pressure: f32,
    pub tilt_x: f32,
    pub tilt_y: f32,
    pub rotation: Option<f64>,
}

impl PointerInputData {
    pub(crate) fn from_arkui_event(event: &ArkUIInputEvent) -> Self {
        let pointer_count = event.pointer_count();
        #[cfg(feature = "mouse")]
        let mouse_buttons_pressed = if event.event_type == UIInputEvent::Mouse {
            let mut buttons = [0; 8];
            match event.mouse_pressed_buttons(&mut buttons) {
                Ok(count) => Some(count > 0),
                Err(error) => {
                    #[cfg(feature = "log")]
                    log::warn!("Failed to snapshot pressed mouse buttons: {error:?}");
                    #[cfg(not(feature = "log"))]
                    eprintln!("Failed to snapshot pressed mouse buttons: {error:?}");
                    None
                }
            }
        } else {
            None
        };
        #[cfg(not(feature = "mouse"))]
        let mouse_buttons_pressed = None;
        Self {
            event_type: event.event_type,
            action: event.action,
            source_type: event.source_type,
            tool_type: event.tool_type,
            x: event.pointer_x(),
            y: event.pointer_y(),
            window_x: event.pointer_window_x(),
            window_y: event.pointer_window_y(),
            display_x: event.pointer_display_x(),
            display_y: event.pointer_display_y(),
            timestamp: event.event_time(),
            pointer_count,
            pointer_id: (pointer_count > 0).then(|| event.pointer_id(0)),
            mouse_buttons_pressed,
            stylus: (event.tool_type == UIInputToolType::Pen && pointer_count > 0).then(|| {
                StylusInputData {
                    pressure: event.pointer_pressure(0),
                    tilt_x: event.pointer_tilt_x(0),
                    tilt_y: event.pointer_tilt_y(0),
                    #[cfg(feature = "stylus")]
                    rotation: event.pointer_roll_angle().ok(),
                    #[cfg(not(feature = "stylus"))]
                    rotation: None,
                }
            }),
        }
    }
}

impl From<GestureInputData> for PointerInputData {
    fn from(event: GestureInputData) -> Self {
        Self {
            event_type: event.event_type,
            action: event.action,
            source_type: event.source_type,
            tool_type: event.tool_type,
            x: event.x,
            y: event.y,
            window_x: event.window_x,
            window_y: event.window_y,
            display_x: event.display_x,
            display_y: event.display_y,
            timestamp: event.timestamp,
            pointer_count: event.pointer_count,
            pointer_id: event.pointer_id,
            mouse_buttons_pressed: None,
            stylus: None,
        }
    }
}

/// Owned mouse-wheel, touchpad, or rotary-axis scroll data.
///
/// The underlying ArkUI input object is only valid during the native callback, so the framework
/// snapshots its useful values before delivering the event to the application.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AxisEventData {
    pub pointer: PointerInputData,
    pub delta_x: f64,
    pub delta_y: f64,
}

/// System-recognized gestures emitted according to [`TouchInputDelivery`].
///
/// Consumers can use [`GestureEvent::Tap`] as a semantic click, [`GestureEvent::Pan`] as a
/// scroll-ready stream, and [`GestureEvent::Swipe`] to seed fling or momentum behavior. ArkUI,
/// rather than each rendering framework, owns gesture recognition and threshold handling.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum GestureEvent {
    Tap(TapGestureEvent),
    Pan(PanGestureEvent),
    Swipe(SwipeGestureEvent),
}

/// System-recognized single tap with its originating pointer data.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TapGestureEvent {
    pub pointer: PointerInputData,
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
    pub pointer: PointerInputData,
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
    pub pointer: PointerInputData,
    pub phase: GesturePhase,
    pub angle: f32,
    pub velocity: f32,
}

#[derive(Clone)]
pub enum ImeEvent {
    TextInputEvent(TextInputEventData),
    PreviewTextEvent { text: String, start: i32, end: i32 },
    FinishPreviewEvent,
    BackspaceEvent(i32),
    DeleteForwardEvent(i32),
    MoveCursorEvent(Direction),
    SelectionEvent { start: i32, end: i32 },
    ExtendActionEvent(Action),
    ImeStatusEvent(KeyboardStatus),
    EnterEvent(i32),
}

impl Debug for ImeEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImeEvent::TextInputEvent(data) => write!(f, "TextInputEvent: {:?}", data),
            ImeEvent::PreviewTextEvent { text, start, end } => {
                write!(f, "PreviewTextEvent: {text:?} ({start}..{end})")
            }
            ImeEvent::FinishPreviewEvent => write!(f, "FinishPreviewEvent"),
            ImeEvent::BackspaceEvent(len) => write!(f, "BackspaceEvent: delete length is {}", len),
            ImeEvent::DeleteForwardEvent(len) => write!(f, "DeleteForwardEvent: {len}"),
            ImeEvent::MoveCursorEvent(direction) => write!(f, "MoveCursorEvent: {direction:?}"),
            ImeEvent::SelectionEvent { start, end } => write!(f, "SelectionEvent: {start}..{end}"),
            ImeEvent::ExtendActionEvent(action) => write!(f, "ExtendActionEvent: {action:?}"),
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
        let event = InputEvent::XComponent(XComponentInputEvent::Mouse(MouseEventData {
            x: 12.5,
            y: 24.0,
            screen_x: 112.5,
            screen_y: 224.0,
            timestamp: 42,
            action: MouseAction::Move,
            button: MouseButton::NoneButton,
        }));

        let output = format!("{event:?}");
        assert!(output.starts_with("XComponent: Mouse(MouseEventData"));
        assert!(output.contains("action: Move"));
        assert!(output.contains("button: NoneButton"));
    }

    #[test]
    fn gesture_event_debug_output_includes_scroll_delta() {
        let event = InputEvent::ArkUi(ArkUiInputEvent::Gesture(GestureEvent::Pan(
            PanGestureEvent {
                pointer: pointer_input(),
                phase: GesturePhase::Update,
                delta_x: 2.0,
                delta_y: -4.0,
                offset_x: 12.0,
                offset_y: 24.0,
                velocity: 6.0,
                velocity_x: 3.0,
                velocity_y: -5.0,
            },
        )));

        let output = format!("{event:?}");
        assert!(output.starts_with("ArkUi: Gesture(Pan(PanGestureEvent"));
        assert!(output.contains("phase: Update"));
        assert!(output.contains("delta_y: -4.0"));
    }

    fn pointer_input() -> PointerInputData {
        PointerInputData {
            event_type: UIInputEvent::Touch,
            action: UIInputAction::Move,
            source_type: UIInputSourceType::TouchScreen,
            tool_type: UIInputToolType::Finger,
            x: 10.0,
            y: 20.0,
            window_x: 10.0,
            window_y: 20.0,
            display_x: 10.0,
            display_y: 20.0,
            timestamp: 42,
            pointer_count: 1,
            pointer_id: Some(0),
            mouse_buttons_pressed: None,
            stylus: None,
        }
    }

    #[test]
    fn touch_delivery_selects_exact_streams() {
        assert!(TouchInputDelivery::RawXComponent.delivers_raw_touch());
        assert!(!TouchInputDelivery::RawXComponent.delivers_arkui_gestures());
        assert!(!TouchInputDelivery::ArkUiGestures.delivers_raw_touch());
        assert!(TouchInputDelivery::ArkUiGestures.delivers_arkui_gestures());
        assert!(TouchInputDelivery::Both.delivers_raw_touch());
        assert!(TouchInputDelivery::Both.delivers_arkui_gestures());
    }
}
