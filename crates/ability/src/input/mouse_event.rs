use ohos_xcomponent_binding::MouseButton;
use ohos_xcomponent_sys::OH_NativeXComponent_MouseEvent;

/// Input source types from OHOS NDK.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputSourceType {
    Unknown,
    Mouse,
    TouchScreen,
    Touchpad,
    Joystick,
    Keyboard,
}

impl From<i32> for InputSourceType {
    fn from(value: i32) -> Self {
        match value {
            1 => InputSourceType::Mouse,
            2 => InputSourceType::TouchScreen,
            3 => InputSourceType::Touchpad,
            4 => InputSourceType::Joystick,
            5 => InputSourceType::Keyboard,
            _ => InputSourceType::Unknown,
        }
    }
}

/// Mouse action types for OHOS mouse events.
///
/// Maps to `OH_NativeXComponent_MouseEventAction` from the NDK, with additional
/// hover variants synthesized from `DispatchHoverEvent` callbacks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseAction {
    None,
    Press,
    Release,
    Move,
    /// Synthesized from DispatchHoverEvent(isHover=true)
    HoverEnter,
    /// Synthesized from DispatchHoverEvent(isHover=false)
    HoverLeave,
}

impl From<u32> for MouseAction {
    fn from(value: u32) -> Self {
        match value {
            0 => MouseAction::None,
            1 => MouseAction::Press,
            2 => MouseAction::Release,
            3 => MouseAction::Move,
            _ => MouseAction::None,
        }
    }
}

impl From<ohos_xcomponent_binding::MouseAction> for MouseAction {
    fn from(value: ohos_xcomponent_binding::MouseAction) -> Self {
        match value {
            ohos_xcomponent_binding::MouseAction::Press => MouseAction::Press,
            ohos_xcomponent_binding::MouseAction::Release => MouseAction::Release,
            ohos_xcomponent_binding::MouseAction::Move => MouseAction::Move,
            _ => MouseAction::None,
        }
    }
}

/// Safe Rust wrapper around `OH_NativeXComponent_MouseEvent` FFI struct.
///
/// Also carries hover events synthesized from `DispatchHoverEvent`.
#[derive(Debug, Clone)]
pub struct MouseEventData {
    pub x: f32,
    pub y: f32,
    pub screen_x: f32,
    pub screen_y: f32,
    pub timestamp: i64,
    pub action: MouseAction,
    pub button: MouseButton,
}

impl Default for MouseEventData {
    fn default() -> Self {
        Self {
            x: 0.0,
            y: 0.0,
            screen_x: 0.0,
            screen_y: 0.0,
            timestamp: 0,
            action: MouseAction::None,
            button: MouseButton::NoneButton,
        }
    }
}

impl From<OH_NativeXComponent_MouseEvent> for MouseEventData {
    fn from(raw: OH_NativeXComponent_MouseEvent) -> Self {
        Self {
            x: raw.x,
            y: raw.y,
            screen_x: raw.screenX,
            screen_y: raw.screenY,
            timestamp: raw.timestamp,
            action: MouseAction::from(raw.action),
            button: MouseButton::from(raw.button),
        }
    }
}

impl MouseEventData {
    /// Create a hover event (enter or leave) from DispatchHoverEvent callback.
    ///
    /// Hover events from the NDK don't carry position data, so x/y are zeroed.
    pub fn hover(is_hover: bool) -> Self {
        Self {
            action: if is_hover {
                MouseAction::HoverEnter
            } else {
                MouseAction::HoverLeave
            },
            ..Default::default()
        }
    }
}

impl From<ohos_xcomponent_binding::MouseEventData> for MouseEventData {
    fn from(data: ohos_xcomponent_binding::MouseEventData) -> Self {
        Self {
            x: data.x,
            y: data.y,
            screen_x: data.screen_x,
            screen_y: data.screen_y,
            timestamp: data.timestamp,
            action: data.action.into(),
            button: data.button,
        }
    }
}

// NOTE: the legacy NDK callback infrastructure (set_mouse_event_callback /
// set_axis_event_callback / register_mouse_callbacks and the thread-local dispatchers)
// was removed 2026-08-24: the main tree routes mouse/axis events through the
// ohos-arkui-binding crate (xcomponent.rs `register_mouse_event_callback` /
// `on_mouse_event`), leaving this free-function path with zero callers.
// MouseEventData / AxisEventData and their conversions remain live via InputEvent.

// ─── Axis (scroll wheel) event support ────────────────────────────────────────

/// Scroll axis event data extracted from ArkUI axis events.
///
/// Carries scroll deltas, pinch scale, and the input source type
/// (mouse vs touchpad) so that consumers can differentiate behavior.
#[derive(Debug, Clone)]
pub struct AxisEventData {
    /// Horizontal scroll delta (positive = scroll right).
    pub delta_x: f32,
    /// Vertical scroll delta (positive = scroll down).
    pub delta_y: f32,
    /// Pinch scale factor from two-finger pinch on touchpad.
    /// 1.0 = no change, >1.0 = zoom in, <1.0 = zoom out.
    /// 0.0 = no pinch data in this event.
    pub pinch_scale: f32,
    /// Source of the input event (mouse, touchpad, touchscreen, etc.).
    pub source_type: InputSourceType,
    /// Event timestamp in nanoseconds.
    pub timestamp: i64,
}

impl Default for AxisEventData {
    fn default() -> Self {
        Self {
            delta_x: 0.0,
            delta_y: 0.0,
            pinch_scale: 0.0,
            source_type: InputSourceType::Unknown,
            timestamp: 0,
        }
    }
}

// Axis events are dispatched by the ohos-arkui-binding crate (xcomponent.rs),
// which constructs AxisEventData directly; the legacy NDK dispatch path here
// had zero callers and was removed with the rest of the callback infra above.

#[cfg(test)]
mod tests {
    use ohos_xcomponent_sys::OH_NativeXComponent_MouseEvent;

    use super::*;

    #[test]
    fn input_source_type_from_i32_covers_all_values() {
        assert!(matches!(InputSourceType::from(1), InputSourceType::Mouse));
        assert!(matches!(
            InputSourceType::from(2),
            InputSourceType::TouchScreen
        ));
        assert!(matches!(
            InputSourceType::from(3),
            InputSourceType::Touchpad
        ));
        assert!(matches!(
            InputSourceType::from(4),
            InputSourceType::Joystick
        ));
        assert!(matches!(
            InputSourceType::from(5),
            InputSourceType::Keyboard
        ));
        assert!(matches!(
            InputSourceType::from(99),
            InputSourceType::Unknown
        ));
        assert!(matches!(InputSourceType::from(0), InputSourceType::Unknown));
    }

    #[test]
    fn mouse_action_from_u32_covers_all_values() {
        assert!(matches!(MouseAction::from(0u32), MouseAction::None));
        assert!(matches!(MouseAction::from(1u32), MouseAction::Press));
        assert!(matches!(MouseAction::from(2u32), MouseAction::Release));
        assert!(matches!(MouseAction::from(3u32), MouseAction::Move));
        assert!(matches!(MouseAction::from(99u32), MouseAction::None));
    }

    #[test]
    fn mouse_action_from_binding_variants() {
        use ohos_xcomponent_binding::MouseAction as BindingMouseAction;
        let conv = |v: BindingMouseAction| MouseAction::from(v);
        assert!(matches!(conv(BindingMouseAction::None), MouseAction::None));
        assert!(matches!(
            conv(BindingMouseAction::Press),
            MouseAction::Press
        ));
        assert!(matches!(
            conv(BindingMouseAction::Release),
            MouseAction::Release
        ));
        assert!(matches!(conv(BindingMouseAction::Move), MouseAction::Move));
    }

    #[test]
    fn mouse_event_data_from_raw_ndk_event() {
        // OHOS NDK action=2 (release), button=1 (left)
        let raw = OH_NativeXComponent_MouseEvent {
            x: 1.5,
            y: 2.5,
            screenX: 10.5,
            screenY: 20.5,
            timestamp: 77,
            action: 2,
            button: 1,
        };
        let data = MouseEventData::from(raw);
        assert_eq!(data.x, 1.5);
        assert_eq!(data.y, 2.5);
        assert_eq!(data.screen_x, 10.5);
        assert_eq!(data.screen_y, 20.5);
        assert_eq!(data.timestamp, 77);
        assert!(matches!(data.action, MouseAction::Release));
        assert!(matches!(data.button, MouseButton::LeftButton));
    }

    #[test]
    fn hover_events_carry_enter_leave_action() {
        let enter = MouseEventData::hover(true);
        assert!(matches!(enter.action, MouseAction::HoverEnter));
        assert_eq!(enter.x, 0.0);
        let leave = MouseEventData::hover(false);
        assert!(matches!(leave.action, MouseAction::HoverLeave));
    }

    #[test]
    fn mouse_event_data_from_binding_event() {
        let binding = ohos_xcomponent_binding::MouseEventData {
            x: 3.5,
            y: 4.5,
            screen_x: 30.5,
            screen_y: 40.5,
            timestamp: 9,
            action: ohos_xcomponent_binding::MouseAction::Press,
            button: MouseButton::RightButton,
        };
        let data = MouseEventData::from(binding);
        assert_eq!(data.x, 3.5);
        assert_eq!(data.screen_y, 40.5);
        assert!(matches!(data.action, MouseAction::Press));
        assert!(matches!(data.button, MouseButton::RightButton));
    }

    #[test]
    fn defaults_are_neutral() {
        let m = MouseEventData::default();
        assert!(matches!(m.action, MouseAction::None));
        assert!(matches!(m.button, MouseButton::NoneButton));
        assert_eq!(m.timestamp, 0);
        let a = AxisEventData::default();
        assert!(matches!(a.source_type, InputSourceType::Unknown));
        assert_eq!(a.delta_x, 0.0);
        assert_eq!(a.pinch_scale, 0.0);
    }
}
