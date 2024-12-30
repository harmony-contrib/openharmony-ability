#[derive(Clone)]
pub enum RectChangeReason {
    Undefined = 0,
    Maximize,
    Recover,
    Move,
    Drag,
    DragStart,
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
