//! Device configuration snapshot types (mirrors `@ohos.app.ability.Configuration`).

use super::{ColorMode, Direction, ScreenDensity};

#[derive(Clone, PartialEq)]
/// Device configuration reported by the OHOS ability environment.
///
/// Populated from the ArkTS `onConfigurationUpdate` callback; every field
/// mirrors the identically named property of
/// `@ohos.app.ability.Configuration`.
pub struct Configuration {
    /// Current application language (BCP-47 tag, e.g. `"zh-Hans-CN"`);
    /// empty until the first configuration push.
    pub language: String,
    /// Selected color mode (dark/light) or [`ColorMode::NoSet`].
    pub color_mode: ColorMode,
    /// Screen orientation (vertical/horizontal) or [`Direction::NoSet`].
    pub direction: Direction,
    /// Screen density bucket or [`ScreenDensity::NoSet`].
    pub screen_density: ScreenDensity,
    /// Logical display id the configuration belongs to.
    pub display_id: i32,
    /// `true` when the device has a pointer (mouse/touchpad) input device.
    pub has_pointer_device: bool,
    /// Font size scale factor relative to the base size (1.0 = unscaled).
    pub font_size_scale: f64,
    /// Font weight scale factor relative to the base weight (1.0 = unscaled).
    pub font_weight_scale: f64,
    /// Mobile country code of the current network; empty when unavailable.
    pub mcc: String,
    /// Mobile network code of the current network; empty when unavailable.
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
