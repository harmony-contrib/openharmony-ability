//! Content-rect change reasons (mirrors `@ohos.window.RectChangeReason`).

#[derive(Clone)]
/// Why a window's content rectangle changed.
pub enum RectChangeReason {
    /// Unknown or platform-unreported reason (OHOS value 0).
    Undefined = 0,
    /// Window was maximized.
    Maximize,
    /// Window recovered from maximized/fullscreen state.
    Recover,
    /// Window was moved without resizing.
    Move,
    /// Window is being dragged (continuous updates during the drag).
    Drag,
    /// A window drag started.
    DragStart,
    /// A window drag ended.
    DragEnd,
}

impl From<i32> for RectChangeReason {
    fn from(value: i32) -> Self {
        match value {
            0 => RectChangeReason::Undefined,
            1 => RectChangeReason::Maximize,
            2 => RectChangeReason::Recover,
            3 => RectChangeReason::Move,
            4 => RectChangeReason::Drag,
            5 => RectChangeReason::DragStart,
            6 => RectChangeReason::DragEnd,
            _ => RectChangeReason::Undefined,
        }
    }
}
