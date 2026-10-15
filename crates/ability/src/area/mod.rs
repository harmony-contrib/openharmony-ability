mod avoid;
mod rect;
mod rect_reason;
mod size;

pub use avoid::*;
pub use rect::*;
pub use rect_reason::*;
pub use size::*;

#[derive(Clone)]
pub struct ContentRect {
    pub reason: RectChangeReason,
    pub rect: Rect,
    /// Window this rect change originated from (0 = main window, >0 = Float sub-window).
    /// Populated by the window_rect_change lifecycle closure from the windowId wrapped
    /// into the options by ArkTS (design.md D2). Phase 2 does not consume this field in
    /// tao's run_loop (the match arm stays unchanged); Phase 3 routes the event by it.
    pub window_id: i64,
}
