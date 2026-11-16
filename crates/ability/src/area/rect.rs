//! Rectangle primitive (mirrors the OHOS `Rect` shape).

#[derive(Debug, Clone, Copy, PartialEq, Default)]
/// Axis-aligned rectangle in window/display coordinates.
pub struct Rect {
    /// Y coordinate of the top edge.
    pub top: i32,
    /// X coordinate of the left edge.
    pub left: i32,
    /// Width in pixels.
    pub width: i32,
    /// Height in pixels.
    pub height: i32,
}
