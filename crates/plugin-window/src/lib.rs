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

/// Rust facade marker for the built-in `ohos.window` plugin (async; requires
/// the UI-context readiness signal).
pub struct WindowBridgePlugin;

impl BridgePlugin for WindowBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.window";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::UiContext];
}

/// Request for one system avoid-area of the component window.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AvoidAreaRequest {
    /// Raw OHOS `AvoidAreaType` value (`AvoidAreaType::into()` of the Rust enum).
    pub area_type: i32,
}

impl_bridge_napi_type!(AvoidAreaRequest, "ohos.window.AvoidAreaRequest");

/// Response carrying the requested avoid area in raw wire shape.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AvoidAreaResponse {
    /// Raw avoid-area payload; convert with `Into<AvoidArea>`.
    pub area: RawAvoidArea,
}

impl_bridge_napi_type!(AvoidAreaResponse, "ohos.window.AvoidAreaResponse");

/// Raw (wire-shape) avoid area as reported by the ArkTS side.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct RawAvoidArea {
    /// Whether the area currently occludes the window.
    pub visible: bool,
    /// Docked panel / system dock on the left edge.
    pub left_rect: RawRect,
    /// Status bar / notch area on the top edge.
    pub top_rect: RawRect,
    /// Scrollbar or split-screen divider on the right edge.
    pub right_rect: RawRect,
    /// Navigation indicator / keyboard on the bottom edge.
    pub bottom_rect: RawRect,
}

/// Raw (wire-shape) rectangle in physical px.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct RawRect {
    /// Top offset in px.
    pub top: i32,
    /// Left offset in px.
    pub left: i32,
    /// Width in px.
    pub width: i32,
    /// Height in px.
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

/// Request to create and fully configure one OS sub-window.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowCreateRequest {
    /// Window name (ArkTS sub-window tag); must not be blank.
    pub name: String,
    /// Initial window width in px (must be positive).
    pub width: i32,
    /// Initial window height in px (must be positive).
    pub height: i32,
    /// Initial left offset in px.
    pub x: i32,
    /// Initial top offset in px.
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
        if self.width <= 0_i32 || self.height <= 0_i32 {
            return Err(Error::from_reason(
                "window width and height must be positive",
            ));
        }
        Ok(())
    }
}

/// Response carrying the OHOS-assigned sub-window id.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowCreateResponse {
    /// OHOS window id (NOT the tao NEXT_WINDOW_ID placeholder registry).
    pub window_id: i64,
}

impl_bridge_napi_type!(WindowCreateResponse, "ohos.window.CreateResponse");

/// Generic one-window request (window id only).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowIdRequest {
    /// Target window id (0 = main/UIAbility window).
    pub window_id: i64,
}

impl_bridge_napi_type!(WindowIdRequest, "ohos.window.WindowIdRequest");

/// Request to toggle window decorations.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowDecorationsRequest {
    /// Target window id.
    pub window_id: i64,
    /// `true` shows the title bar / drag area / close button.
    pub decorations: bool,
}

impl_bridge_napi_type!(WindowDecorationsRequest, "ohos.window.DecorationsRequest");

/// Request to toggle immersive fullscreen layout.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowFullscreenRequest {
    /// Target window id.
    pub window_id: i64,
    /// `true` enters fullscreen (`setWindowLayoutFullScreen(true)` + hide bars).
    pub on: bool,
}

impl_bridge_napi_type!(WindowFullscreenRequest, "ohos.window.FullscreenRequest");

/// Request to set the window background color.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowColorRequest {
    /// Target window id.
    pub window_id: i64,
    /// Background color in 0xAARRGGBB format.
    pub color: u32,
}

impl_bridge_napi_type!(WindowColorRequest, "ohos.window.ColorRequest");

/// Request to set the window shadow (background blur) radius.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowBlurRequest {
    /// Target window id.
    pub window_id: i64,
    /// Shadow radius in vp (non-negative finite; ArkTS gates API level).
    pub radius: f64,
}

impl_bridge_napi_type!(WindowBlurRequest, "ohos.window.BlurRequest");

/// Request to move a window's top-left corner.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowMoveRequest {
    /// Target window id.
    pub window_id: i64,
    /// New left offset in px (JavaScript-safe integer).
    pub x: i64,
    /// New top offset in px (JavaScript-safe integer).
    pub y: i64,
}

impl_bridge_napi_type!(WindowMoveRequest, "ohos.window.MoveRequest");

/// Request to resize a window (outer or drawable size depending on action).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowResizeRequest {
    /// Target window id.
    pub window_id: i64,
    /// New width in px (positive, JavaScript-safe integer).
    pub width: i64,
    /// New height in px (positive, JavaScript-safe integer).
    pub height: i64,
}

impl_bridge_napi_type!(WindowResizeRequest, "ohos.window.ResizeRequest");

/// Request to set whether a window can take focus.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowFocusableRequest {
    /// Target window id.
    pub window_id: i64,
    /// `true` allows the window to become focused.
    pub focusable: bool,
}

impl_bridge_napi_type!(WindowFocusableRequest, "ohos.window.FocusableRequest");

/// Request to set whether a window consumes touch/mouse events.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowTouchableRequest {
    /// Target window id.
    pub window_id: i64,
    /// `false` makes the window click-through (pass-through).
    pub touchable: bool,
}

impl_bridge_napi_type!(WindowTouchableRequest, "ohos.window.TouchableRequest");

/// Request to keep a window above all others.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowTopmostRequest {
    /// Target window id.
    pub window_id: i64,
    /// `true` pins the window on top (API14+ + WINDOW_TOPMOST permission).
    pub topmost: bool,
}

impl_bridge_napi_type!(WindowTopmostRequest, "ohos.window.TopmostRequest");

/// Request to set the window title text.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowTitleRequest {
    /// Target window id.
    pub window_id: i64,
    /// New title (at most 1024 characters).
    pub title: String,
}

impl_bridge_napi_type!(WindowTitleRequest, "ohos.window.TitleRequest");

/// Request to set min/max window size limits.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowLimitsRequest {
    /// Target window id.
    pub window_id: i64,
    /// Minimum width in px (0 = no limit).
    pub min_width: i64,
    /// Minimum height in px (0 = no limit).
    pub min_height: i64,
    /// Maximum width in px (0 = no limit).
    pub max_width: i64,
    /// Maximum height in px (0 = no limit).
    pub max_height: i64,
}

impl_bridge_napi_type!(WindowLimitsRequest, "ohos.window.LimitsRequest");

/// Request to inform the IME of the cursor rect.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ImePositionRequest {
    /// Target window id.
    pub window_id: i64,
    /// Cursor left in physical px.
    pub x: i64,
    /// Cursor top in physical px.
    pub y: i64,
}

impl_bridge_napi_type!(ImePositionRequest, "ohos.window.ImePositionRequest");

/// Response for the IME position update (soft rejection, not a bridge error).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ImePositionResponse {
    /// `true` when the IME accepted the cursor rect.
    pub ok: bool,
    /// OHOS error code (`12800009` = no focused editor, normal when absent).
    pub code: i32,
    /// Human-readable failure reason when `ok` is `false`.
    pub message: String,
}

impl_bridge_napi_type!(ImePositionResponse, "ohos.window.ImePositionResponse");

/// Request for edge-drag / resize-by-drag toggles (shared wire shape).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowDraggableRequest {
    /// Target window id.
    pub window_id: i64,
    /// `true` allows the user drag operation.
    pub enable: bool,
}

impl_bridge_napi_type!(WindowDraggableRequest, "ohos.window.DraggableRequest");

/// Request to set the pointer cursor style for one window.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct CursorIconRequest {
    /// Target window id.
    pub window_id: i64,
    /// PointerStyle id as understood by WindowManager.setPointerStyle.
    pub style: i32,
}

impl_bridge_napi_type!(CursorIconRequest, "ohos.window.CursorIconRequest");

/// Request to set the global pointer visibility.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct CursorVisibleRequest {
    /// Global pointer visibility. `pointer.setPointerVisible` is process-wide
    /// (not per-window), so this request deliberately carries no window id.
    pub visible: bool,
}

impl_bridge_napi_type!(CursorVisibleRequest, "ohos.window.CursorVisibleRequest");

/// Request to apply the decoration flag bit-field.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct DecorationFlagsRequest {
    /// Target window id.
    pub window_id: i64,
    /// FLAG bit-field (closable=1, maximizable=2, minimizable=4, resizable=8).
    pub flags: i32,
}

impl_bridge_napi_type!(DecorationFlagsRequest, "ohos.window.DecorationFlagsRequest");

/// Response carrying the resolved real OHOS window id.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct RealWindowIdResponse {
    /// Native OHOS window id (usable with `OH_WindowManager_*` C APIs).
    pub window_id: i64,
}

impl_bridge_napi_type!(RealWindowIdResponse, "ohos.window.RealWindowIdResponse");

/// System geometry snapshot for one window (issue Eulogizethesun/tauri#97):
/// both rects come from ONE `win.getWindowProperties()` call, so they can never
/// tear. `window_rect` = WM/outer rect; `drawable_rect` = the drawable
/// (content) area — position relative to the window top-left, size in px.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowRectsResponse {
    /// Outer (window-manager) rectangle in physical px.
    pub window_rect: RawRect,
    /// Drawable (content) rectangle in physical px.
    pub drawable_rect: RawRect,
}

impl_bridge_napi_type!(WindowRectsResponse, "ohos.window.RectsResponse");

/// Generic acknowledgement for window operations.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowAcknowledgement {
    /// `true` when the ArkTS side accepted the operation.
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

/// Boolean state query response (`is-maximized` / `is-minimized`).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowStateResponse {
    /// Queried state value.
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

/// Shared argument validation for the outer-size (`resize`) and inner-size
/// (`resize-inner`) bridge calls.
fn validate_resize_args(window_id: i64, width: i64, height: i64) -> Result<()> {
    validate_window_id(window_id)?;
    if width <= 0 || height <= 0 {
        return Err(Error::from_reason(
            "window width and height must be positive",
        ));
    }
    validate_platform_integer("width", width)?;
    validate_platform_integer("height", height)?;
    Ok(())
}

/// Worker-safe facade for component-window queries and OS sub-window management.
#[derive(Clone)]
pub struct WindowClient {
    bridge: BridgeRuntime,
}

impl WindowClient {
    /// Builds a window client bound to the app's bridge session.
    ///
    /// # Errors
    /// Fails when the app has no active bridge session yet.
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

    /// Sets whether the window is decorated with native title bar controls.
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
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

    /// Sets the window background color as a 32-bit ARGB value.
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
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
        if !radius.is_finite() || radius < 0.0_f64 {
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

    /// Moves input focus to the window.
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
    pub async fn focus_window(&self, window_id: i64) -> Result<()> {
        self.window_command("focus", window_id).await
    }

    /// Sets whether the window can take input focus.
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
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

    /// Moves the window's top-left corner to (`x`, `y`) in px.
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
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

    /// Resizes the window to `width` x `height` in px.
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
    pub async fn resize_window(&self, window_id: i64, width: i64, height: i64) -> Result<()> {
        validate_resize_args(window_id, width, height)?;
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

    /// Resizes the window so its DRAWABLE (content) area becomes exactly
    /// `width` × `height` px (issue Eulogizethesun/tauri#97).
    ///
    /// The inner→outer conversion happens on the ArkTS side at dispatch time,
    /// from one atomic `getWindowProperties()` snapshot
    /// (`outer = inner + (windowRect − drawableRect)` per axis). No estimate is
    /// ever involved — the value is the system's own chrome. If the precise
    /// chrome cannot be read (window not created/destroyed, content not loaded,
    /// degenerate drawableRect), the call FAILS explicitly instead of resizing
    /// to a guessed size: the caller is expected to warn and skip, never to
    /// fall back to an estimated decor.
    pub async fn resize_inner_window(&self, window_id: i64, width: i64, height: i64) -> Result<()> {
        validate_resize_args(window_id, width, height)?;
        self.call::<WindowResizeRequest, WindowAcknowledgement>(
            "resize-inner",
            WindowResizeRequest {
                window_id,
                width,
                height,
            },
        )
        .await?
        .ensure()
    }

    /// Queries the system geometry for one window in a single atomic
    /// `getWindowProperties()` snapshot: the WM (outer) rect and the drawable
    /// (system-defined inner) rect, both in physical px (issue Eulogizethesun/tauri#97).
    ///
    /// This is the authoritative read-back source for verifying
    /// [`Self::resize_inner_window`] landed the requested inner size — assert
    /// against `drawable_rect`, not against any tao-side derived inner size.
    pub async fn get_window_rects(&self, window_id: i64) -> Result<(Rect, Rect)> {
        validate_window_id(window_id)?;
        let response = self
            .call::<WindowIdRequest, WindowRectsResponse>(
                "get-window-rects",
                WindowIdRequest { window_id },
            )
            .await?;
        Ok((response.window_rect.into(), response.drawable_rect.into()))
    }

    /// Minimizes the window.
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
    pub async fn minimize_window(&self, window_id: i64) -> Result<()> {
        self.window_command("minimize", window_id).await
    }

    /// Maximizes the window.
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
    pub async fn maximize_window(&self, window_id: i64) -> Result<()> {
        self.window_command("maximize", window_id).await
    }

    /// Exits the maximized state (OHOS `Window.restore`).
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
    pub async fn restore_window(&self, window_id: i64) -> Result<()> {
        self.window_command("restore", window_id).await
    }

    /// Recovers the window size from the maximized or minimized state
    /// (OHOS `Window.recover`).
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
    pub async fn recover_window(&self, window_id: i64) -> Result<()> {
        self.window_command("recover", window_id).await
    }

    /// Shows the window.
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
    pub async fn show_window(&self, window_id: i64) -> Result<()> {
        self.window_command("show", window_id).await
    }

    /// Destroys one OS sub-window and releases its plugin-local handle.
    pub async fn destroy_window(&self, window_id: i64) -> Result<()> {
        self.window_command("destroy-window", window_id).await
    }

    /// Returns `true` when the window is currently maximized.
    ///
    /// # Errors
    /// Fails when the bridge rejects the query.
    pub async fn is_window_maximized(&self, window_id: i64) -> Result<bool> {
        self.window_state("is-maximized", window_id).await
    }

    /// Returns `true` when the window is currently minimized.
    ///
    /// # Errors
    /// Fails when the bridge rejects the query.
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

    /// Sets the window title text.
    ///
    /// # Errors
    /// Fails when the bridge rejects the operation.
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

    /// Allows/forbids USER-initiated resizing (issue Eulogizethesun/tauri#104):
    /// the real "resizable" switch, as opposed to the decoration-flag bit that
    /// only toggles title-bar button visibility. The ArkTS side routes by
    /// windowId (id 0 = the main window), not by window kind: id 0 ->
    /// `setResizeByDragEnabled` (API 14+, effective in free-window state),
    /// any non-zero id (sub-window or spawned UIAbility instance) ->
    /// `enableDrag` (API 20+). Programmatic resizes are gated separately by
    /// the FLAG_RESIZABLE decoration bit on the Rust side.
    pub async fn set_resize_by_drag(&self, window_id: i64, enable: bool) -> Result<()> {
        validate_window_id(window_id)?;
        self.call::<WindowDraggableRequest, WindowAcknowledgement>(
            "set-resize-by-drag",
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
    ///
    /// Issue #238 contract: every UIAbility MAIN window is rejected by the
    /// ArkTS `WindowManager.setDecorationFlags` branch -- its decoration
    /// buttons are OS-managed and the platform has no API that maps to the
    /// operation-level enable/disable flag semantics -- so the bridge invoke
    /// rejects and this method surfaces the ArkTS error text ("...not supported
    /// on the OpenHarmony main window..."). Only sub-windows honor the flags
    /// (LocalStorage-driven sub-window page buttons). The rejection is
    /// kind-based, not id-based: the ArkTS branch keys on
    /// `WindowManager.isUIAbilityMainWindow` (WindowManager.ets), which rejects
    /// the primary instance's id 0 AND a spawned UIAbility instance's id > 0 --
    /// a subsequent UIAbility instance has id > 0 but is still a system-managed
    /// main window. The Rust side adds NO gate of its own: every
    /// UIAbility-main-window id must reach the ArkTS throw, so the caller
    /// always sees the platform rejection, never a Rust validation message
    /// (pinned for the id-0 path by
    /// `ut_decoration_flags_main_window_error_is_surfaced_from_the_arkts_throw`).
    ///
    /// # Errors
    /// - The ArkTS main-window rejection when `window_id` is a UIAbility main
    ///   window (kind-based per `WindowManager.isUIAbilityMainWindow`: the
    ///   primary's id 0, or a spawned UIAbility instance's id > 0) -- accepted
    ///   by the Rust-side validation on purpose -- see #238 above.
    /// - The Rust-side [`validate_window_id`] error for negative ids: the only
    ///   error this facade produces itself for this call.
    /// - The bridge-transport errors (session not ready, invoke timeout,
    ///   rejection) surfaced by [`WindowClient::call`].
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
    /// Returns the window plugin client bound to this app's bridge session.
    ///
    /// # Errors
    /// Fails when the app has no active bridge session yet.
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
        validate_platform_integer, validate_resize_args, validate_window_id, AvoidAreaRequest,
        AvoidAreaResponse, DecorationFlagsRequest, RawAvoidArea, RawRect, WindowBridgePlugin,
        MAX_SAFE_JAVASCRIPT_INTEGER,
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

    // Issue #238: the main window's decoration buttons are OS-managed -- the
    // ArkTS WindowManager.setDecorationFlags main-window branch now THROWS
    // (former hilog no-op acked a fake success), so the set-decoration-flags
    // bridge invoke rejects and the facade surfaces the ArkTS error text
    // ("...not supported on the OpenHarmony main window..."). A host UT cannot
    // round-trip a live bridge (no N-API Env); the host-testable half of that
    // contract is that the facade must NOT pre-gate the main-window id
    // Rust-side (the Err the caller sees must be the ArkTS throw, not a Rust
    // validation message) and that the request payload carries the exact named
    // wire contract the ArkTS isUIAbilityMainWindow branch keys on. Coverage
    // note: the api demo device suite (tauri repo, window-ops ut_
    // decoration-reject cases) regexes /not supported on OpenHarmony/, which
    // is the Rust-side tauri-runtime-wry message; this repo's ArkTS throw
    // inserts "the" plus a window id, so it does not match, and window-ops
    // only touches set-decoration-flags on the sub-window success path. The ArkTS
    // error text itself therefore has no end-to-end assertion -- the host UT
    // below pins the non-pre-gate + payload contract only.
    #[test]
    fn ut_decoration_flags_main_window_error_is_surfaced_from_the_arkts_throw() {
        // Brief:
        // 1. Main-window id 0 passes validate_window_id -- the facade dispatches
        //    it (no Rust-side gate); the rejection is the ArkTS throw.
        // 2. The DecorationFlagsRequest wire contract name is the frozen string
        //    the ArkTS bridge arm + isUIAbilityMainWindow branch consume.
        // 3. Negative ids are still rejected Rust-side -- the only error the
        //    facade itself produces for this call.
        assert!(validate_window_id(0).is_ok());
        assert_eq!(
            <DecorationFlagsRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.window.DecorationFlagsRequest"
        );
        assert!(validate_window_id(-1).is_err());
    }

    #[test]
    fn ut_decoration_flags_facade_body_has_no_rust_side_main_window_pregate() {
        // Brief (A55R-5 review follow-up): the test above pins that id 0 passes
        // the shared validation, but a future main-window pre-gate added inside
        // the `set_window_decoration_flags` body (before the dispatch) would
        // still turn the #238 Err into a Rust validation message. A live
        // behavioral probe ("call the facade and assert the error comes from
        // the transport, not a Rust gate") is not executable on the host:
        // `BridgeRuntime` is only constructible from a real N-API Env, so a
        // `WindowClient` cannot be built here (same limitation recorded on
        // `validate_resize_args`). The next-strongest enforceable assertion
        // pins the facade body itself: it must keep the shared window-id
        // validation, dispatch the frozen wire request, and contain none of the
        // shapes a main-window pre-gate would take (an id comparison, an early
        // `return Err`, or a delegate to a main-window classifier). This fails
        // the build the moment such a gate is added to the facade.
        let src = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/lib.rs"));
        let body = facade_fn_body(src, "set_window_decoration_flags");
        assert!(
            body.contains("validate_window_id(window_id)"),
            "set_window_decoration_flags must keep the shared window-id validation"
        );
        assert!(
            body.contains("DecorationFlagsRequest { window_id, flags }"),
            "set_window_decoration_flags must dispatch the frozen DecorationFlagsRequest wire contract"
        );
        for pregate_marker in [
            "window_id == 0",
            "window_id != 0",
            "window_id > 0",
            "window_id < 0",
            "return Err(",
            "is_uiability_main_window",
            "isUIAbilityMainWindow",
        ] {
            assert!(
                !body.contains(pregate_marker),
                "set_window_decoration_flags gained a Rust-side main-window pre-gate \
                 (marker {pregate_marker:?}) -- the #238 Err must come from the ArkTS throw, \
                 not from a Rust-side gate"
            );
        }
    }

    /// Slices the body of one `fn <name>(...)` definition out of a source file.
    ///
    /// Returns everything from the `fn` keyword to the next item boundary (the
    /// next doc comment or `pub` item at the impl-block indent). Good enough
    /// for the uniformly rustfmt-formatted facade methods in this file; the
    /// assertion fails loudly if the function is renamed or removed.
    fn facade_fn_body<'a>(src: &'a str, fn_name: &str) -> &'a str {
        let needle = format!("fn {fn_name}(");
        let start = src.find(&needle).unwrap_or_else(|| {
            panic!("facade fn {fn_name} not found in lib.rs");
        });
        let rest = &src[start..];
        let next_doc = rest.find("\n    ///").unwrap_or(rest.len());
        let next_item = rest.find("\n    pub ").unwrap_or(rest.len());
        &rest[..next_doc.min(next_item)]
    }

    #[test]
    fn rects_response_uses_stable_named_napi_contract() {
        // Issue Eulogizethesun/tauri#97: the geometry query contract name is
        // frozen — the ArkTS side dispatches on this string.
        assert_eq!(
            <super::WindowRectsResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.window.RectsResponse"
        );
    }

    #[test]
    fn rects_response_converts_raw_rects_to_framework_rects() {
        use super::WindowRectsResponse;
        // Distinct top/left so a top↔left swap in either RawRect → Rect conversion
        // fails this test (issue #97 review: identical values would hide it).
        let response = WindowRectsResponse {
            window_rect: RawRect {
                top: 76,
                left: 113,
                width: 2090,
                height: 1394,
            },
            // Reference-device shape (HAD-W32): 146px title bar on top, content
            // below; small left inset keeps the width math honest too.
            drawable_rect: RawRect {
                top: 146,
                left: 7,
                width: 2083,
                height: 1248,
            },
        };
        let outer: Rect = response.window_rect.into();
        let drawable: Rect = response.drawable_rect.into();
        assert_eq!((outer.top, outer.left), (76_i32, 113_i32));
        assert_eq!((drawable.top, drawable.left), (146_i32, 7_i32));
        // Vertical chrome = title bar; horizontal chrome = left inset.
        assert_eq!(outer.height - drawable.height, 146_i32);
        assert_eq!(outer.width - drawable.width, 7_i32);
    }

    #[test]
    fn validate_resize_args_rejects_zero_negative_and_overflow() {
        // Shared validator of resize (outer-size, lib.rs resize_window) and
        // resize-inner (lib.rs resize_inner_window) — both call sites must keep
        // invoking validate_resize_args before self.call; host tests cannot
        // construct a WindowClient (bridge session required, see
        // OpenHarmonyApp::bridge), so that linkage is enforced by review only
        // (issue #97 review finding).
        assert!(validate_resize_args(0, 800, 600).is_ok());
        assert!(validate_resize_args(0, 0, 600).is_err());
        assert!(validate_resize_args(0, 800, -1).is_err());
        assert!(validate_resize_args(-1, 800, 600).is_err());
        assert!(validate_resize_args(0, MAX_SAFE_JAVASCRIPT_INTEGER + 1, 600).is_err());
    }
}
