#[derive(Debug)]
pub enum Direction {
    NoSet = -1,
    Vertical,
    Horizontal,
}

impl From<i32> for Direction {
    fn from(value: i32) -> Self {
        match value {
            0 => Direction::Vertical,
            1 => Direction::Horizontal,
            _ => Direction::NoSet,
        }
    }
}