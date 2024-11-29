pub enum StageEventType {
    Shown = 1,
    Active,
    Inactive,
    Hidden,
    Resumed,
    Paused,
}

impl From<i32> for StageEventType {
    fn from(value: i32) -> Self {
        match value {
            1 => StageEventType::Shown,
            2 => StageEventType::Active,
            3 => StageEventType::Inactive,
            4 => StageEventType::Hidden,
            5 => StageEventType::Resumed,
            6 => StageEventType::Paused,
            _ => panic!("Invalid StageEventType value: {}", value),
        }
    }
}
