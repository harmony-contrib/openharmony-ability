mod rect;
mod rect_reason;
mod size;

pub use rect::*;
pub use rect_reason::*;
pub use size::*;

#[derive(Clone)]
pub struct ContentRect {
    pub reason: RectChangeReason,
    pub rect: Rect,
}
