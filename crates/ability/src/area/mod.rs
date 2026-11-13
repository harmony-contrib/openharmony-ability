//! Geometry primitives shared by the event and area modules.

mod avoid;
mod rect;
mod rect_reason;
mod size;

pub use avoid::*;
pub use rect::*;
pub use rect_reason::*;
pub use size::*;

#[derive(Clone)]
/// Content (safe) rectangle of a window with the reason for its last change.
pub struct ContentRect {
    /// What triggered the rect change.
    pub reason: RectChangeReason,
    /// The new content rectangle in window coordinates.
    pub rect: Rect,
    /// Window this rect change originated from (0 = primary main window; any
    /// positive value = a sub-window or a spawned UIAbility instance, which
    /// registers its own resize callbacks under its abilityWindowId > 0).
    /// Populated by the window_rect_change lifecycle closure from the windowId wrapped
    /// into the options by ArkTS (design.md D2). Phase 2 does not consume this field in
    /// tao's run_loop (the match arm stays unchanged); Phase 3 routes the event by it.
    pub window_id: i64,
}
