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
pub struct WindowFullscreenRequest {
    pub window_id: i64,
    pub on: bool,
}

impl_bridge_napi_type!(WindowFullscreenRequest, "ohos.window.FullscreenRequest");

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
pub struct WindowTouchableRequest {
    pub window_id: i64,
    pub touchable: bool,
}

impl_bridge_napi_type!(WindowTouchableRequest, "ohos.window.TouchableRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowTopmostRequest {
    pub window_id: i64,
    pub topmost: bool,
}

impl_bridge_napi_type!(WindowTopmostRequest, "ohos.window.TopmostRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowTitleRequest {
    pub window_id: i64,
    pub title: String,
}

impl_bridge_napi_type!(WindowTitleRequest, "ohos.window.TitleRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowLimitsRequest {
    pub window_id: i64,
    pub min_width: i64,
    pub min_height: i64,
    pub max_width: i64,
    pub max_height: i64,
}

impl_bridge_napi_type!(WindowLimitsRequest, "ohos.window.LimitsRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ImePositionRequest {
    pub window_id: i64,
    pub x: i64,
    pub y: i64,
}

impl_bridge_napi_type!(ImePositionRequest, "ohos.window.ImePositionRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ImePositionResponse {
    pub ok: bool,
    pub code: i32,
    pub message: String,
}

impl_bridge_napi_type!(ImePositionResponse, "ohos.window.ImePositionResponse");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowDraggableRequest {
    pub window_id: i64,
    pub enable: bool,
}

impl_bridge_napi_type!(WindowDraggableRequest, "ohos.window.DraggableRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct CursorIconRequest {
    pub window_id: i64,
    /// PointerStyle id as understood by WindowManager.setPointerStyle.
    pub style: i32,
}

impl_bridge_napi_type!(CursorIconRequest, "ohos.window.CursorIconRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct CursorVisibleRequest {
    /// Global pointer visibility. `pointer.setPointerVisible` is process-wide
    /// (not per-window), so this request deliberately carries no window id.
    pub visible: bool,
}

impl_bridge_napi_type!(CursorVisibleRequest, "ohos.window.CursorVisibleRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct DecorationFlagsRequest {
    pub window_id: i64,
    /// FLAG bit-field (closable=1, maximizable=2, minimizable=4, resizable=8).
    pub flags: i32,
}

impl_bridge_napi_type!(DecorationFlagsRequest, "ohos.window.DecorationFlagsRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct RealWindowIdResponse {
    pub window_id: i64,
}

impl_bridge_napi_type!(RealWindowIdResponse, "ohos.window.RealWindowIdResponse");

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
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
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
    ///
    /// NOTE: no production callers — window creation goes through the core path
    /// (`openharmony_ability::window::create_os_window`, NEXT_WINDOW_ID + TSFN →
    /// WindowManager.createSubWindow), which tao's `Window::new` invokes. This
    /// bridge-path variant returns an OHOS-assigned id disconnected from the
    /// NEXT_WINDOW_ID registry (no tao Window, no per-window rect registration,
    /// not tracked by window-state). See openspec change
    /// p1-window-state-per-window-rect design.md Non-Goals, and
    /// docs/decoupling-plan-v2.md N12 — if that migration ever routes window
    /// creation through this client, id-registry alignment + rect registration
    /// must be designed as part of it.
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

    /// Toggles immersive fullscreen layout. `on=true` enters fullscreen
    /// (`setWindowLayoutFullScreen(true)` + hide system bars); `on=false`
    /// reverses it. Replaces the legacy top-level `set_fullscreen` which went
    /// through the dead `get_helper()` transport.
    pub async fn set_fullscreen(&self, window_id: i64, on: bool) -> Result<()> {
        validate_window_id(window_id)?;
        self.call::<WindowFullscreenRequest, WindowAcknowledgement>(
            "set-fullscreen",
            WindowFullscreenRequest { window_id, on },
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

    /// Sets whether a window consumes touch/mouse events.
    ///
    /// `touchable = false` makes the window pass-through (maps to the consumer's
    /// ignore-cursor-events API). The negation is applied by the windowing backend caller.
    pub async fn set_window_touchable(&self, window_id: i64, touchable: bool) -> Result<()> {
        validate_window_id(window_id)?;
        self.call::<WindowTouchableRequest, WindowAcknowledgement>(
            "set-touchable",
            WindowTouchableRequest {
                window_id,
                touchable,
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

    /// Keeps the window above all others. Requires API14+ and the
    /// `ohos.permission.WINDOW_TOPMOST` permission (ArkTS side rejects otherwise).
    pub async fn set_window_topmost(&self, window_id: i64, topmost: bool) -> Result<()> {
        validate_window_id(window_id)?;
        self.call::<WindowTopmostRequest, WindowAcknowledgement>(
            "set-topmost",
            WindowTopmostRequest { window_id, topmost },
        )
        .await?
        .ensure()
    }

    pub async fn set_window_title(&self, window_id: i64, title: String) -> Result<()> {
        validate_window_id(window_id)?;
        if title.chars().count() > 1024 {
            return Err(Error::from_reason(
                "window title must be at most 1024 characters",
            ));
        }
        self.call::<WindowTitleRequest, WindowAcknowledgement>(
            "set-title",
            WindowTitleRequest { window_id, title },
        )
        .await?
        .ensure()
    }

    /// Sets min/max window size limits in physical pixels; 0 means no limit
    /// (system default). Requires API11+.
    pub async fn set_window_limits(
        &self,
        window_id: i64,
        min_width: i64,
        min_height: i64,
        max_width: i64,
        max_height: i64,
    ) -> Result<()> {
        validate_window_id(window_id)?;
        for (name, value) in [
            ("minWidth", min_width),
            ("minHeight", min_height),
            ("maxWidth", max_width),
            ("maxHeight", max_height),
        ] {
            if value < 0 {
                return Err(Error::from_reason(format!(
                    "window limit {name} must be non-negative"
                )));
            }
            validate_platform_integer(name, value)?;
        }
        self.call::<WindowLimitsRequest, WindowAcknowledgement>(
            "set-limits",
            WindowLimitsRequest {
                window_id,
                min_width,
                min_height,
                max_width,
                max_height,
            },
        )
        .await?
        .ensure()
    }

    /// Emulates user attention via a system notification. Fire-and-forget on the
    /// ArkTS side: publish failures (including the 1600004 enable-notification
    /// retry path) are logged, not propagated — attention is best-effort.
    pub async fn request_user_attention(&self, window_id: i64) -> Result<()> {
        self.window_command("request-user-attention", window_id)
            .await
    }

    /// Notifies the IME of the cursor rect (physical pixels). Requires a focused
    /// editor; `ok=false, code=12800009` means none was focused, which is normal.
    pub async fn set_ime_position(
        &self,
        window_id: i64,
        x: i64,
        y: i64,
    ) -> Result<ImePositionResponse> {
        validate_window_id(window_id)?;
        validate_platform_integer("x coordinate", x)?;
        validate_platform_integer("y coordinate", y)?;
        self.call::<ImePositionRequest, ImePositionResponse>(
            "set-ime-position",
            ImePositionRequest { window_id, x, y },
        )
        .await
    }

    /// Allows/forbids edge-drag resizing. Requires API20+.
    pub async fn set_window_draggable(&self, window_id: i64, enable: bool) -> Result<()> {
        validate_window_id(window_id)?;
        self.call::<WindowDraggableRequest, WindowAcknowledgement>(
            "set-draggable",
            WindowDraggableRequest { window_id, enable },
        )
        .await?
        .ensure()
    }

    /// Sets the pointer cursor style for one window (PointerStyle id, resolved
    /// by the caller from `window::CursorIcon`; ArkTS validates the range).
    pub async fn set_cursor_icon(&self, window_id: i64, style: i32) -> Result<()> {
        validate_window_id(window_id)?;
        self.call::<CursorIconRequest, WindowAcknowledgement>(
            "set-cursor-icon",
            CursorIconRequest { window_id, style },
        )
        .await?
        .ensure()
    }

    /// Sets the GLOBAL pointer visibility (pointer.setPointerVisible — there
    /// is no per-window variant on OHOS). Restores the dispatch that the
    /// bridge facade migration (tao 73212e1e) dropped to a no-op, breaking
    /// `set_cursor_visible` on the Rust side even though the ArkTS
    /// WindowManager.setPointerVisible implementation survived.
    pub async fn set_cursor_visible(&self, visible: bool) -> Result<()> {
        self.call::<CursorVisibleRequest, WindowAcknowledgement>(
            "set-cursor-visible",
            CursorVisibleRequest { visible },
        )
        .await?
        .ensure()
    }

    /// Applies the decoration flag bit-field (closable=1, maximizable=2,
    /// minimizable=4, resizable=8) that gates the matching window operations
    /// on the ArkTS side.
    pub async fn set_window_decoration_flags(&self, window_id: i64, flags: i32) -> Result<()> {
        validate_window_id(window_id)?;
        self.call::<DecorationFlagsRequest, WindowAcknowledgement>(
            "set-decoration-flags",
            DecorationFlagsRequest { window_id, flags },
        )
        .await?
        .ensure()
    }

    /// Resolves the tao placeholder window id (0 = main window) to the real
    /// OHOS window id required by native `OH_WindowManager_*` C APIs.
    pub async fn get_real_window_id(&self, window_id: i64) -> Result<i64> {
        validate_window_id(window_id)?;
        let real_id = self
            .call::<WindowIdRequest, RealWindowIdResponse>(
                "get-real-window-id",
                WindowIdRequest { window_id },
            )
            .await?
            .window_id;
        validate_window_id(real_id)?;
        Ok(real_id)
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
        RawAvoidArea, RawRect, WindowBridgePlugin, MAX_SAFE_JAVASCRIPT_INTEGER,
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
