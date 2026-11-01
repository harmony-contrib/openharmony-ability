use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Object, Result};

use super::{ColorMode, Direction, ScreenDensity};

#[derive(Clone, Debug, PartialEq)]
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

/// Optional N-API representation of OpenHarmony's `@ohos.app.ability.Configuration`.
///
/// Every property on the ArkTS `Configuration` interface is optional, and
/// `UIAbility.onConfigurationUpdate` may deliver partial delta objects or omit fields
/// such as `mcc`/`mnc` on Wi-Fi-only devices. Parsing into optional fields allows both
/// `AbilityInitContext` startup seeding and `onConfigurationUpdated` runtime updates to
/// merge cleanly onto an existing [`Configuration`] without failing N-API conversion.
#[napi(object)]
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AbilityInitConfiguration {
    pub language: Option<String>,
    pub color_mode: Option<i32>,
    pub direction: Option<i32>,
    pub screen_density: Option<i32>,
    pub display_id: Option<i32>,
    pub has_pointer_device: Option<bool>,
    pub font_size_scale: Option<f64>,
    pub font_weight_scale: Option<f64>,
    pub mcc: Option<String>,
    pub mnc: Option<String>,
}

impl AbilityInitConfiguration {
    pub fn from_object(configuration: &Object<'_>) -> Result<Self> {
        Ok(Self {
            language: configuration.get("language")?,
            color_mode: configuration.get("colorMode")?,
            direction: configuration.get("direction")?,
            screen_density: configuration.get("screenDensity")?,
            display_id: configuration.get("displayId")?,
            has_pointer_device: configuration.get("hasPointerDevice")?,
            font_size_scale: configuration.get("fontSizeScale")?,
            font_weight_scale: configuration.get("fontWeightScale")?,
            mcc: configuration.get("mcc")?,
            mnc: configuration.get("mnc")?,
        })
    }

    pub fn apply_to(&self, base: &Configuration) -> Configuration {
        Configuration {
            language: self
                .language
                .clone()
                .unwrap_or_else(|| base.language.clone()),
            color_mode: self
                .color_mode
                .map(ColorMode::from)
                .unwrap_or(base.color_mode),
            direction: self
                .direction
                .map(Direction::from)
                .unwrap_or(base.direction),
            screen_density: self
                .screen_density
                .map(ScreenDensity::from)
                .unwrap_or(base.screen_density),
            display_id: self.display_id.unwrap_or(base.display_id),
            has_pointer_device: self.has_pointer_device.unwrap_or(base.has_pointer_device),
            font_size_scale: self.font_size_scale.unwrap_or(base.font_size_scale),
            font_weight_scale: self.font_weight_scale.unwrap_or(base.font_weight_scale),
            mcc: self.mcc.clone().unwrap_or_else(|| base.mcc.clone()),
            mnc: self.mnc.clone().unwrap_or_else(|| base.mnc.clone()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_update_preserves_base_configuration() {
        let base = Configuration {
            language: "zh-Hans".to_string(),
            color_mode: ColorMode::Light,
            direction: Direction::Horizontal,
            screen_density: ScreenDensity::XXLDPI,
            display_id: 2,
            has_pointer_device: true,
            font_size_scale: 1.25,
            font_weight_scale: 1.1,
            mcc: "460".to_string(),
            mnc: "01".to_string(),
        };

        let merged = AbilityInitConfiguration::default().apply_to(&base);
        assert_eq!(merged, base);
    }

    #[test]
    fn partial_update_overrides_only_present_fields() {
        let base = Configuration {
            language: "en-US".to_string(),
            color_mode: ColorMode::Light,
            direction: Direction::Horizontal,
            screen_density: ScreenDensity::XLDPI,
            display_id: 0,
            has_pointer_device: true,
            font_size_scale: 1.0,
            font_weight_scale: 1.0,
            mcc: String::new(),
            mnc: String::new(),
        };

        let delta = AbilityInitConfiguration {
            color_mode: Some(0),
            font_size_scale: Some(1.15),
            ..Default::default()
        };

        let merged = delta.apply_to(&base);
        assert_eq!(merged.color_mode, ColorMode::Dark);
        assert_eq!(merged.font_size_scale, 1.15);
        assert_eq!(merged.language, "en-US");
        assert_eq!(merged.direction, Direction::Horizontal);
        assert_eq!(merged.screen_density, ScreenDensity::XLDPI);
        assert!(merged.has_pointer_device);
    }
}
