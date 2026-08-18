//! Asynchronous window plugin facade.
//!
//! Capabilities: `get-avoid-area` and multi-window operations (create OS sub-windows,
//! decorations, focus, move/resize/minimize/maximize, background color, blur and destruction).

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, AvoidArea, AvoidAreaType, BridgeCallOptions,
    BridgeContextRequirement, BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp, Rect,
};

pub struct WindowBridgePlugin;

impl BridgePlugin for WindowBridgePlugin {
    type Mode = AsyncBridge;

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

const MAX_SAFE_JAVASCRIPT_INTEGER: i64 = 9_007_199_254_740_991;

fn validate_window_id(window_id: i64) -> Result<()> {
    if !(0..=MAX_SAFE_JAVASCRIPT_INTEGER).contains(&window_id) {
        return Err(Error::from_reason(
            "window id must be a non-negative JavaScript-safe integer",
        ));
    }
    Ok(())
}

fn validate_platform_integer(name: &str, value: i64) -> Result<()> {
    if !(-MAX_SAFE_JAVASCRIPT_INTEGER..=MAX_SAFE_JAVASCRIPT_INTEGER).contains(&value) {
        return Err(Error::from_reason(format!(
            "window {name} must be a JavaScript-safe integer"
        )));
    }
    Ok(())
}

/// Worker-safe facade for component-window queries and OS sub-window management.
#[derive(Clone)]
pub struct WindowClient {
    bridge: BridgeRuntime,
}

impl WindowClient {
    fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }

    async fn call<Request, Response>(&self, action: &str, request: Request) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.bridge
            .call_async::<WindowBridgePlugin, Request, Response>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await
    }

    /// Queries the avoid area of the Window that owns the attached DefaultXComponent.
    pub async fn query_avoid_area(&self, area_type: AvoidAreaType) -> Result<AvoidArea> {
        let response = self
            .call::<AvoidAreaRequest, AvoidAreaResponse>(
                "get-avoid-area",
                AvoidAreaRequest {
                    area_type: area_type.into(),
                },
            )
            .await?;
        Ok(response.area.into())
    }

    /// Creates and fully configures an OS sub-window before returning its platform window id.
    pub async fn create_os_window(&self, request: WindowCreateRequest) -> Result<i64> {
        request.validate()?;
        let window_id = self
            .call::<WindowCreateRequest, WindowCreateResponse>("create-os-window", request)
            .await?
            .window_id;
        validate_window_id(window_id)?;
        Ok(window_id)
    }

    pub async fn set_window_decorations(&self, window_id: i64, decorations: bool) -> Result<()> {
        validate_window_id(window_id)?;
        self.call::<WindowDecorationsRequest, WindowAcknowledgement>(
            "set-decorations",
            WindowDecorationsRequest {
                window_id,
                decorations,
            },
        )
        .await?
        .ensure()
    }

    pub async fn set_window_background_color(&self, window_id: i64, color: u32) -> Result<()> {
        validate_window_id(window_id)?;
        self.call::<WindowColorRequest, WindowAcknowledgement>(
            "set-background-color",
            WindowColorRequest { window_id, color },
        )
        .await?
        .ensure()
    }

    /// Sets the platform sub-window shadow radius. The ArkTS side rejects unsupported API levels.
    pub async fn set_window_blur(&self, window_id: i64, radius: f64) -> Result<()> {
        validate_window_id(window_id)?;
        if !radius.is_finite() || radius < 0.0 {
            return Err(Error::from_reason(
                "window shadow radius must be a non-negative finite number",
            ));
        }
        self.call::<WindowBlurRequest, WindowAcknowledgement>(
            "set-blur",
            WindowBlurRequest { window_id, radius },
        )
        .await?
        .ensure()
    }

    pub async fn focus_window(&self, window_id: i64) -> Result<()> {
        self.window_command("focus", window_id).await
    }

    pub async fn set_window_focusable(&self, window_id: i64, focusable: bool) -> Result<()> {
        validate_window_id(window_id)?;
        self.call::<WindowFocusableRequest, WindowAcknowledgement>(
            "set-focusable",
            WindowFocusableRequest {
                window_id,
                focusable,
            },
        )
        .await?
        .ensure()
    }

    pub async fn move_window_to(&self, window_id: i64, x: i64, y: i64) -> Result<()> {
        validate_window_id(window_id)?;
        validate_platform_integer("x coordinate", x)?;
        validate_platform_integer("y coordinate", y)?;
        self.call::<WindowMoveRequest, WindowAcknowledgement>(
            "move-to",
            WindowMoveRequest { window_id, x, y },
        )
        .await?
        .ensure()
    }

    pub async fn resize_window(&self, window_id: i64, width: i64, height: i64) -> Result<()> {
        validate_window_id(window_id)?;
        if width <= 0 || height <= 0 {
            return Err(Error::from_reason(
                "window width and height must be positive",
            ));
        }
        validate_platform_integer("width", width)?;
        validate_platform_integer("height", height)?;
        self.call::<WindowResizeRequest, WindowAcknowledgement>(
            "resize",
            WindowResizeRequest {
                window_id,
                width,
                height,
            },
        )
        .await?
        .ensure()
    }

    pub async fn minimize_window(&self, window_id: i64) -> Result<()> {
        self.window_command("minimize", window_id).await
    }

    pub async fn maximize_window(&self, window_id: i64) -> Result<()> {
        self.window_command("maximize", window_id).await
    }

    pub async fn restore_window(&self, window_id: i64) -> Result<()> {
        self.window_command("restore", window_id).await
    }

    pub async fn recover_window(&self, window_id: i64) -> Result<()> {
        self.window_command("recover", window_id).await
    }

    pub async fn show_window(&self, window_id: i64) -> Result<()> {
        self.window_command("show", window_id).await
    }

    /// Destroys one OS sub-window and releases its plugin-local handle.
    pub async fn destroy_window(&self, window_id: i64) -> Result<()> {
        self.window_command("destroy-window", window_id).await
    }

    pub async fn is_window_maximized(&self, window_id: i64) -> Result<bool> {
        self.window_state("is-maximized", window_id).await
    }

    pub async fn is_window_minimized(&self, window_id: i64) -> Result<bool> {
        self.window_state("is-minimized", window_id).await
    }

    async fn window_command(&self, action: &str, window_id: i64) -> Result<()> {
        validate_window_id(window_id)?;
        self.call::<WindowIdRequest, WindowAcknowledgement>(action, WindowIdRequest { window_id })
            .await?
            .ensure()
    }

    async fn window_state(&self, action: &str, window_id: i64) -> Result<bool> {
        validate_window_id(window_id)?;
        Ok(self
            .call::<WindowIdRequest, WindowStateResponse>(action, WindowIdRequest { window_id })
            .await?
            .value)
    }
}

/// Extension trait supplied by the capability package, never by framework core.
pub trait WindowExt {
    fn window(&self) -> Result<WindowClient>;
}

impl WindowExt for OpenHarmonyApp {
    fn window(&self) -> Result<WindowClient> {
        WindowClient::new(self)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        validate_platform_integer, validate_window_id, AvoidAreaRequest, AvoidAreaResponse,
        RawAvoidArea, RawRect, WindowAcknowledgement, WindowBlurRequest, WindowBridgePlugin,
        WindowColorRequest, WindowCreateRequest, WindowCreateResponse, WindowDecorationsRequest,
        WindowFocusableRequest, WindowIdRequest, WindowMoveRequest, WindowResizeRequest,
        WindowStateResponse, MAX_SAFE_JAVASCRIPT_INTEGER,
    };
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
    fn multi_window_actions_use_stable_named_napi_contracts() {
        assert_eq!(
            <WindowCreateRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.window.CreateRequest"
        );
        assert_eq!(
            <WindowCreateResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.window.CreateResponse"
        );
        assert_eq!(
            <WindowIdRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.window.WindowIdRequest"
        );
        assert_eq!(
            <WindowDecorationsRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.window.DecorationsRequest"
        );
        assert_eq!(
            <WindowColorRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.window.ColorRequest"
        );
        assert_eq!(
            <WindowBlurRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.window.BlurRequest"
        );
        assert_eq!(
            <WindowMoveRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.window.MoveRequest"
        );
        assert_eq!(
            <WindowResizeRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.window.ResizeRequest"
        );
        assert_eq!(
            <WindowFocusableRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.window.FocusableRequest"
        );
        assert_eq!(
            <WindowAcknowledgement as BridgeNapiType>::TYPE_NAME,
            "ohos.window.Acknowledgement"
        );
        assert_eq!(
            <WindowStateResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.window.StateResponse"
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

    #[test]
    fn window_handles_and_geometry_stay_javascript_safe() {
        assert!(validate_window_id(0).is_ok());
        assert!(validate_window_id(MAX_SAFE_JAVASCRIPT_INTEGER).is_ok());
        assert!(validate_window_id(-1).is_err());
        assert!(validate_window_id(MAX_SAFE_JAVASCRIPT_INTEGER + 1).is_err());
        assert!(validate_platform_integer("x", -MAX_SAFE_JAVASCRIPT_INTEGER).is_ok());
        assert!(validate_platform_integer("x", MAX_SAFE_JAVASCRIPT_INTEGER + 1).is_err());
    }
}
