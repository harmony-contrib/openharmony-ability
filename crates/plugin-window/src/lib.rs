//! Main-thread window plugin facade.
//!
//! Capabilities: `get-avoid-area` and multi-window operations (create OS sub-windows,
//! decorations, focus, move/resize/minimize/maximize, background color and blur).

use napi_derive_ohos::napi;
use napi_ohos::{Env, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AvoidArea, AvoidAreaType, BridgeContextRequirement, BridgePlugin,
    MainThreadSyncBridge, OpenHarmonyApp, Rect,
};

pub struct WindowBridgePlugin;

impl BridgePlugin for WindowBridgePlugin {
    type Mode = MainThreadSyncBridge;

    const ID: &'static str = "ohos.window";
    const VERSION: u32 = 2;
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

// ── Multi-window operations ────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowCreateRequest {
    pub name: String,
    pub width: i32,
    pub height: i32,
    pub x: i32,
    pub y: i32,
    /// Whether to show window decorations (title bar, drag area, close button).
    pub decorations: bool,
    /// Fully transparent window background.
    pub transparent: bool,
    /// Window background color in 0xAARRGGBB format; ignored when `transparent` is true.
    pub background_color: Option<u32>,
}

impl_bridge_napi_type!(WindowCreateRequest, "ohos.window.CreateRequest");

impl WindowCreateRequest {
    fn validate(&self) -> Result<()> {
        if self.name.trim().is_empty() {
            return Err(Error::from_reason("window name must not be empty"));
        }
        if self.width <= 0 || self.height <= 0 {
            return Err(Error::from_reason(
                "window width and height must be positive",
            ));
        }
        Ok(())
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowCreateResponse {
    pub window_id: i64,
}

impl_bridge_napi_type!(WindowCreateResponse, "ohos.window.CreateResponse");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowIdRequest {
    pub window_id: i64,
}

impl_bridge_napi_type!(WindowIdRequest, "ohos.window.WindowIdRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowDecorationsRequest {
    pub window_id: i64,
    pub decorations: bool,
}

impl_bridge_napi_type!(WindowDecorationsRequest, "ohos.window.DecorationsRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowColorRequest {
    pub window_id: i64,
    pub color: u32,
}

impl_bridge_napi_type!(WindowColorRequest, "ohos.window.ColorRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowBlurRequest {
    pub window_id: i64,
    pub radius: f64,
}

impl_bridge_napi_type!(WindowBlurRequest, "ohos.window.BlurRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowMoveRequest {
    pub window_id: i64,
    pub x: i64,
    pub y: i64,
}

impl_bridge_napi_type!(WindowMoveRequest, "ohos.window.MoveRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowResizeRequest {
    pub window_id: i64,
    pub width: i64,
    pub height: i64,
}

impl_bridge_napi_type!(WindowResizeRequest, "ohos.window.ResizeRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowFocusableRequest {
    pub window_id: i64,
    pub focusable: bool,
}

impl_bridge_napi_type!(WindowFocusableRequest, "ohos.window.FocusableRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(WindowAcknowledgement, "ohos.window.Acknowledgement");

impl WindowAcknowledgement {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "Window plugin rejected the requested operation",
            ))
        }
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowStateResponse {
    pub value: bool,
}

impl_bridge_napi_type!(WindowStateResponse, "ohos.window.StateResponse");

/// Multi-window extension trait (synchronous, `window-stage` context).
pub trait WindowExtMulti {
    /// Creates an OS-level sub-window; returns its globally unique id.
    fn create_os_window(&self, env: &Env, request: WindowCreateRequest) -> Result<i64>;
    /// Sets window decorations (title bar visibility) at runtime.
    fn set_window_decorations(&self, env: &Env, window_id: i64, decorations: bool) -> Result<()>;
    /// Sets the window background color (0xAARRGGBB).
    fn set_window_background_color(&self, env: &Env, window_id: i64, color: u32) -> Result<()>;
    /// Sets the window backdrop blur radius (vibrancy).
    fn set_window_blur(&self, env: &Env, window_id: i64, radius: f64) -> Result<()>;
    /// Requests keyboard focus for the window.
    fn focus_window(&self, env: &Env, window_id: i64) -> Result<()>;
    /// Sets whether the window can receive focus.
    fn set_window_focusable(&self, env: &Env, window_id: i64, focusable: bool) -> Result<()>;
    /// Moves the window to absolute screen coordinates.
    fn move_window_to(&self, env: &Env, window_id: i64, x: i64, y: i64) -> Result<()>;
    /// Resizes the window.
    fn resize_window(&self, env: &Env, window_id: i64, width: i64, height: i64) -> Result<()>;
    /// Minimizes the window.
    fn minimize_window(&self, env: &Env, window_id: i64) -> Result<()>;
    /// Maximizes the window.
    fn maximize_window(&self, env: &Env, window_id: i64) -> Result<()>;
    /// Restores a minimized/maximized window.
    fn restore_window(&self, env: &Env, window_id: i64) -> Result<()>;
    /// Recovers a hidden window (show + restore).
    fn recover_window(&self, env: &Env, window_id: i64) -> Result<()>;
    /// Shows the window.
    fn show_window(&self, env: &Env, window_id: i64) -> Result<()>;
    /// Queries whether the window is maximized.
    fn is_window_maximized(&self, env: &Env, window_id: i64) -> Result<bool>;
    /// Queries whether the window is minimized.
    fn is_window_minimized(&self, env: &Env, window_id: i64) -> Result<bool>;
}

impl WindowExtMulti for OpenHarmonyApp {
    fn create_os_window(&self, env: &Env, request: WindowCreateRequest) -> Result<i64> {
        request.validate()?;
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<WindowBridgePlugin, WindowCreateRequest, WindowCreateResponse>(
                    "create-os-window",
                    request,
                )?;
            Ok(response.window_id)
        })
    }

    fn set_window_decorations(&self, env: &Env, window_id: i64, decorations: bool) -> Result<()> {
        self.with_main_thread_bridge(env, |bridge| {
            bridge
                .call_sync::<WindowBridgePlugin, WindowDecorationsRequest, WindowAcknowledgement>(
                    "set-decorations",
                    WindowDecorationsRequest {
                        window_id,
                        decorations,
                    },
                )?
                .ensure()
        })
    }

    fn set_window_background_color(&self, env: &Env, window_id: i64, color: u32) -> Result<()> {
        self.with_main_thread_bridge(env, |bridge| {
            bridge
                .call_sync::<WindowBridgePlugin, WindowColorRequest, WindowAcknowledgement>(
                    "set-background-color",
                    WindowColorRequest { window_id, color },
                )?
                .ensure()
        })
    }

    fn set_window_blur(&self, env: &Env, window_id: i64, radius: f64) -> Result<()> {
        if !radius.is_finite() || radius < 0.0 {
            return Err(Error::from_reason(
                "window blur radius must be a non-negative finite number",
            ));
        }
        self.with_main_thread_bridge(env, |bridge| {
            bridge
                .call_sync::<WindowBridgePlugin, WindowBlurRequest, WindowAcknowledgement>(
                    "set-blur",
                    WindowBlurRequest { window_id, radius },
                )?
                .ensure()
        })
    }

    fn focus_window(&self, env: &Env, window_id: i64) -> Result<()> {
        self.with_main_thread_bridge(env, |bridge| {
            bridge
                .call_sync::<WindowBridgePlugin, WindowIdRequest, WindowAcknowledgement>(
                    "focus",
                    WindowIdRequest { window_id },
                )?
                .ensure()
        })
    }

    fn set_window_focusable(&self, env: &Env, window_id: i64, focusable: bool) -> Result<()> {
        self.with_main_thread_bridge(env, |bridge| {
            bridge
                .call_sync::<WindowBridgePlugin, WindowFocusableRequest, WindowAcknowledgement>(
                    "set-focusable",
                    WindowFocusableRequest {
                        window_id,
                        focusable,
                    },
                )?
                .ensure()
        })
    }

    fn move_window_to(&self, env: &Env, window_id: i64, x: i64, y: i64) -> Result<()> {
        self.with_main_thread_bridge(env, |bridge| {
            bridge
                .call_sync::<WindowBridgePlugin, WindowMoveRequest, WindowAcknowledgement>(
                    "move-to",
                    WindowMoveRequest { window_id, x, y },
                )?
                .ensure()
        })
    }

    fn resize_window(&self, env: &Env, window_id: i64, width: i64, height: i64) -> Result<()> {
        if width <= 0 || height <= 0 {
            return Err(Error::from_reason(
                "window width and height must be positive",
            ));
        }
        self.with_main_thread_bridge(env, |bridge| {
            bridge
                .call_sync::<WindowBridgePlugin, WindowResizeRequest, WindowAcknowledgement>(
                    "resize",
                    WindowResizeRequest {
                        window_id,
                        width,
                        height,
                    },
                )?
                .ensure()
        })
    }

    fn minimize_window(&self, env: &Env, window_id: i64) -> Result<()> {
        self.window_command(env, "minimize", window_id)
    }

    fn maximize_window(&self, env: &Env, window_id: i64) -> Result<()> {
        self.window_command(env, "maximize", window_id)
    }

    fn restore_window(&self, env: &Env, window_id: i64) -> Result<()> {
        self.window_command(env, "restore", window_id)
    }

    fn recover_window(&self, env: &Env, window_id: i64) -> Result<()> {
        self.window_command(env, "recover", window_id)
    }

    fn show_window(&self, env: &Env, window_id: i64) -> Result<()> {
        self.window_command(env, "show", window_id)
    }

    fn is_window_maximized(&self, env: &Env, window_id: i64) -> Result<bool> {
        self.window_state(env, "is-maximized", window_id)
    }

    fn is_window_minimized(&self, env: &Env, window_id: i64) -> Result<bool> {
        self.window_state(env, "is-minimized", window_id)
    }
}

trait WindowCommandHelper {
    fn window_command(&self, env: &Env, action: &str, window_id: i64) -> Result<()>;
    fn window_state(&self, env: &Env, action: &str, window_id: i64) -> Result<bool>;
}

impl WindowCommandHelper for OpenHarmonyApp {
    fn window_command(&self, env: &Env, action: &str, window_id: i64) -> Result<()> {
        self.with_main_thread_bridge(env, |bridge| {
            bridge
                .call_sync::<WindowBridgePlugin, WindowIdRequest, WindowAcknowledgement>(
                    action,
                    WindowIdRequest { window_id },
                )?
                .ensure()
        })
    }

    fn window_state(&self, env: &Env, action: &str, window_id: i64) -> Result<bool> {
        self.with_main_thread_bridge(env, |bridge| {
            let response = bridge
                .call_sync::<WindowBridgePlugin, WindowIdRequest, WindowStateResponse>(
                    action,
                    WindowIdRequest { window_id },
                )?;
            Ok(response.value)
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
        assert_eq!(WindowBridgePlugin::VERSION, 2);
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
