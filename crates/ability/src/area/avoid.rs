use crate::Rect;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AvoidAreaType {
    System,
    Cutout,
    SystemGesture,
    Keyboard,
    NavigationIndicator,
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
pub struct AvoidArea {
    pub visible: bool,
    pub left_rect: Rect,
    pub top_rect: Rect,
    pub right_rect: Rect,
    pub bottom_rect: Rect,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AvoidAreaInfo {
    pub area_type: AvoidAreaType,
    pub area: AvoidArea,
}
