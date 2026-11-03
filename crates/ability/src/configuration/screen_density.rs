//! Screen density bucket (mirrors `Configuration.screenDensity`).

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
/// Screen density bucket in dpi.
pub enum ScreenDensity {
    /// Density not set by the system (sentinel).
    NoSet = 0,
    /// Small-density screen (120 dpi).
    SDPI = 120,
    /// Medium-density screen (160 dpi).
    MDPI = 160,
    /// Large-density screen (240 dpi).
    LDPI = 240,
    /// Extra-large-density screen (320 dpi).
    XLDPI = 320,
    /// Extra-extra-large-density screen (480 dpi).
    XXLDPI = 480,
    /// Extra-extra-extra-large-density screen (640 dpi).
    XXXLDPI = 640,
}

impl From<i32> for ScreenDensity {
    fn from(value: i32) -> Self {
        match value {
            120 => ScreenDensity::SDPI,
            160 => ScreenDensity::MDPI,
            240 => ScreenDensity::LDPI,
            320 => ScreenDensity::XLDPI,
            480 => ScreenDensity::XXLDPI,
            640 => ScreenDensity::XXXLDPI,
            _ => ScreenDensity::NoSet,
        }
    }
}
