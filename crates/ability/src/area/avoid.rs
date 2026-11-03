//! Avoid-area types (mirrors `@ohos.window.AvoidAreaType` / `AvoidArea`).

use crate::Rect;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
/// Kind of system area a window must avoid occluding.
pub enum AvoidAreaType {
    /// System bar area (status bar / dock, OHOS type 0).
    System,
    /// Camera notch / punch-hole cutout area (OHOS type 1).
    Cutout,
    /// System gesture area (edges reserved for system gestures, OHOS type 2).
    SystemGesture,
    /// Soft keyboard area (OHOS type 3).
    Keyboard,
    /// Navigation indicator (gesture bar) area (OHOS type 4).
    NavigationIndicator,
    /// Unrecognized type from a newer SDK; carries the raw OHOS code.
    Unknown(i32),
}

impl From<i32> for AvoidAreaType {
    fn from(value: i32) -> Self {
        match value {
            0 => AvoidAreaType::System,
            1 => AvoidAreaType::Cutout,
            2 => AvoidAreaType::SystemGesture,
            3 => AvoidAreaType::Keyboard,
            4 => AvoidAreaType::NavigationIndicator,
            _ => AvoidAreaType::Unknown(value),
        }
    }
}

impl From<AvoidAreaType> for i32 {
    fn from(value: AvoidAreaType) -> Self {
        match value {
            AvoidAreaType::System => 0,
            AvoidAreaType::Cutout => 1,
            AvoidAreaType::SystemGesture => 2,
            AvoidAreaType::Keyboard => 3,
            AvoidAreaType::NavigationIndicator => 4,
            AvoidAreaType::Unknown(value) => value,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
/// Per-edge avoid rectangles for one [`AvoidAreaType`], in window coordinates.
pub struct AvoidArea {
    /// `true` when the area currently affects the window (e.g. keyboard shown).
    pub visible: bool,
    /// Rectangle occluding the left edge.
    pub left_rect: Rect,
    /// Rectangle occluding the top edge.
    pub top_rect: Rect,
    /// Rectangle occluding the right edge.
    pub right_rect: Rect,
    /// Rectangle occluding the bottom edge.
    pub bottom_rect: Rect,
}

#[derive(Debug, Clone, Copy, PartialEq)]
/// One avoid area report: its type plus the per-edge rectangles.
pub struct AvoidAreaInfo {
    /// Which system area this report describes.
    pub area_type: AvoidAreaType,
    /// The per-edge rectangles for that area.
    pub area: AvoidArea,
}
