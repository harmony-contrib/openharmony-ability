//! Main-thread window plugin facade.

use napi_derive_ohos::napi;
use napi_ohos::{Env, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AvoidArea, AvoidAreaType, BridgeContextRequirement, BridgePlugin,
    MainThreadSyncBridge, OpenHarmonyApp, Rect,
};

pub struct WindowBridgePlugin;

impl BridgePlugin for WindowBridgePlugin {
    type Mode = MainThreadSyncBridge;

    const ID: &'static str = "ohos.window";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::UiContext];
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AvoidAreaRequest {
    pub area_type: i32,
}

impl_bridge_napi_type!(AvoidAreaRequest, "ohos.window.AvoidAreaRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AvoidAreaResponse {
    pub area: RawAvoidArea,
}

impl_bridge_napi_type!(AvoidAreaResponse, "ohos.window.AvoidAreaResponse");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct RawAvoidArea {
    pub visible: bool,
    pub left_rect: RawRect,
    pub top_rect: RawRect,
    pub right_rect: RawRect,
    pub bottom_rect: RawRect,
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct RawRect {
    pub top: i32,
    pub left: i32,
    pub width: i32,
    pub height: i32,
}

impl From<RawRect> for Rect {
    fn from(rect: RawRect) -> Self {
        Self {
            top: rect.top,
            left: rect.left,
            width: rect.width,
            height: rect.height,
        }
    }
}

impl From<RawAvoidArea> for AvoidArea {
    fn from(area: RawAvoidArea) -> Self {
        Self {
            visible: area.visible,
            left_rect: area.left_rect.into(),
            top_rect: area.top_rect.into(),
            right_rect: area.right_rect.into(),
            bottom_rect: area.bottom_rect.into(),
        }
    }
}

/// Queries platform window state synchronously and therefore requires a main-thread N-API `Env`.
pub trait WindowExt {
    fn query_avoid_area(&self, env: &Env, area_type: AvoidAreaType) -> Result<AvoidArea>;
}

impl WindowExt for OpenHarmonyApp {
    fn query_avoid_area(&self, env: &Env, area_type: AvoidAreaType) -> Result<AvoidArea> {
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<WindowBridgePlugin, AvoidAreaRequest, AvoidAreaResponse>(
                    "get-avoid-area",
                    AvoidAreaRequest {
                        area_type: area_type.into(),
                    },
                )?;
            Ok(response.area.into())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{AvoidAreaRequest, AvoidAreaResponse, RawAvoidArea, RawRect, WindowBridgePlugin};
    use openharmony_ability::{
        AvoidArea, BridgeContextRequirement, BridgeNapiType, BridgePlugin, Rect,
    };

    #[test]
    fn window_plugin_targets_the_component_window() {
        assert_eq!(WindowBridgePlugin::ID, "ohos.window");
        assert_eq!(
            WindowBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::UiContext]
        );
    }

    #[test]
    fn avoid_area_uses_stable_named_napi_contracts() {
        assert_eq!(
            <AvoidAreaRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.window.AvoidAreaRequest"
        );
        assert_eq!(
            <AvoidAreaResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.window.AvoidAreaResponse"
        );
    }

    #[test]
    fn avoid_area_response_keeps_all_rectangles() {
        let area: AvoidArea = RawAvoidArea {
            visible: true,
            left_rect: RawRect {
                top: 1,
                left: 2,
                width: 3,
                height: 4,
            },
            top_rect: RawRect {
                top: 5,
                left: 6,
                width: 7,
                height: 8,
            },
            right_rect: RawRect {
                top: 9,
                left: 10,
                width: 11,
                height: 12,
            },
            bottom_rect: RawRect {
                top: 13,
                left: 14,
                width: 15,
                height: 16,
            },
        }
        .into();

        assert!(area.visible);
        assert_eq!(
            area.left_rect,
            Rect {
                top: 1,
                left: 2,
                width: 3,
                height: 4,
            }
        );
        assert_eq!(
            area.top_rect,
            Rect {
                top: 5,
                left: 6,
                width: 7,
                height: 8,
            }
        );
        assert_eq!(
            area.right_rect,
            Rect {
                top: 9,
                left: 10,
                width: 11,
                height: 12,
            }
        );
        assert_eq!(
            area.bottom_rect,
            Rect {
                top: 13,
                left: 14,
                width: 15,
                height: 16,
            }
        );
    }
}
