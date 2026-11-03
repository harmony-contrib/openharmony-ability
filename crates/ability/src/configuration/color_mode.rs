//! Application color mode (mirrors `Configuration.colorMode`).

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
/// Color mode of the application.
pub enum ColorMode {
    /// Mode not set by the system (sentinel, OHOS `COLOR_MODE_NOT_SET`).
    NoSet = -1,
    /// Dark mode (OHOS `COLOR_MODE_DARK`).
    Dark = 0,
    /// Light mode (OHOS `COLOR_MODE_LIGHT`).
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
