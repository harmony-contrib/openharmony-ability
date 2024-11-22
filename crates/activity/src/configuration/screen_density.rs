#[derive(Debug)]
pub enum ScreenDensity {
    NoSet = 0,
    SDPI = 120,
    MDPI = 160,
    LDPI = 240,
    XLDPI = 320,
    XXLDPI = 480,
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
