use super::{ColorMode, Direction,ScreenDensity};
use napi_derive_ohos::napi;

#[napi(object)]
pub struct Configuration {
    pub language: String,
    pub color_mode: ColorMode,
    pub direction: Direction,
    pub screen_density: ScreenDensity,
    pub display_id: i32,
    pub has_pointer_device: bool,
    pub font_size_scale: f32,
    pub font_weight_scale: f32,
    pub mcc: String,
    pub mnc: String,
}