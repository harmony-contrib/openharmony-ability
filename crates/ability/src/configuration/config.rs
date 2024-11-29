use super::{ColorMode, Direction, ScreenDensity};

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
