use super::{ColorMode, Direction, ScreenDensity};

#[derive(Clone, PartialEq)]
pub struct Configuration {
    pub language: String,
    pub color_mode: ColorMode,
    pub direction: Direction,
    pub screen_density: ScreenDensity,
    pub display_id: i32,
    pub has_pointer_device: bool,
    pub font_size_scale: f64,
    pub font_weight_scale: f64,
    pub mcc: String,
    pub mnc: String,
}

impl Default for Configuration {
    fn default() -> Self {
        Configuration {
            language: String::new(),
            color_mode: ColorMode::NoSet,
            direction: Direction::NoSet,
            screen_density: ScreenDensity::NoSet,
            display_id: 0,
            has_pointer_device: false,
            font_size_scale: 1.0,
            font_weight_scale: 1.0,
            mcc: String::new(),
            mnc: String::new(),
        }
    }
}
