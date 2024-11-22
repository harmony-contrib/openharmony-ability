mod size;
mod rect;
mod rect_reason;

pub use size::*;
pub use rect::*;
pub use rect_reason::*;

pub struct ContentRect {
    pub reason: RectChangeReason,
    pub rect: Rect,
}