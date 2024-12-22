#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub top: i32,
    pub left: i32,
    pub width: i32,
    pub height: i32,
}

impl Default for Rect {
    fn default() -> Self {
        Rect {
            top: 0,
            left: 0,
            width: 0,
            height: 0,
        }
    }
}
