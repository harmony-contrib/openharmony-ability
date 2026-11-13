//! Screen orientation direction (mirrors `Configuration.direction`).

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
/// Orientation direction of the screen.
pub enum Direction {
    /// Direction not set by the system (sentinel).
    NoSet = -1,
    /// Vertical (portrait) orientation.
    Vertical,
    /// Horizontal (landscape) orientation.
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
