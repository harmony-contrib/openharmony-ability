#[derive(Debug)]
pub enum ColorMode {
    NoSet = -1,
    Dark = 0,
    Light = 1,
}

impl From<i32> for ColorMode {
    fn from(value: i32) -> Self {
        match value {
            0 => ColorMode::Dark,
            1 => ColorMode::Light,
            _ => ColorMode::NoSet,
        }
    }
}
