//! OpenHarmony window operations.
//!
//! Window operations go through the typed bridge facade `WindowClient` in the
//! `plugin-window` crate (e.g. `app.window()?.focus_window(id).await`). Window
//! creation uses `create_os_window` / `WindowCreateParams` — a runtime
//! integration-layer API consumed directly by the embedding runtime.

use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use napi_ohos::threadsafe_function::{
    ThreadsafeCallContext, ThreadsafeFunction, ThreadsafeFunctionCallMode,
};
use napi_ohos::Env;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::OnceLock;

/// Global window ID generator to ensure unique IDs across Rust and ArkTS.
static NEXT_WINDOW_ID: AtomicI64 = AtomicI64::new(1);

/// Parameters for creating a new OS-level window on OpenHarmony.
///
/// `windowId` is not included — it is auto-generated internally by `create_os_window`
/// via `NEXT_WINDOW_ID` to ensure global uniqueness.
pub struct WindowCreateParams {
    /// Window label/name, used as the ArkTS sub-window name.
    pub name: String,
    /// Native module to render into this Float window. Empty keeps the WebView-only path.
    pub native_module_name: Option<String>,
    /// OHOS window type enum value (0=App, 8=Float, etc.)
    pub window_type: i32,
    /// Initial window width in px. Default: 800.
    pub width: i32,
    /// Initial window height in px. Default: 600.
    pub height: i32,
    /// Initial window X position in px. Default: 100.
    pub x: i32,
    /// Initial window Y position in px. Default: 100.
    pub y: i32,
    /// Target display for a floating sub-window. None uses the current display.
    pub display_id: Option<i64>,
    /// Whether to show window decorations (title bar, drag area, close button).
    /// Phase 2: controls FloatPage conditional rendering via LocalStorage.
    pub decorations: bool,
    /// Whether the window background should be fully transparent.
    /// Phase 3: when true, overrides background_color with 0x00000000.
    pub transparent: bool,
    /// Window background color in 0xAARRGGBB format.
    /// Phase 3: ignored when transparent is true.
    pub background_color: Option<u32>,
}

impl Default for WindowCreateParams {
    fn default() -> Self {
        Self {
            name: String::new(),
            native_module_name: None,
            window_type: 0,
            width: 800,
            height: 600,
            x: 100,
            y: 100,
            display_id: None,
            decorations: true,
            transparent: false,
            background_color: None,
        }
    }
}

/// Generates a unique window ID for use when creating sub-windows
/// outside of `create_os_window` (e.g., from `handleWindowNew` when
/// `window_kind == "window"`). Uses the same `NEXT_WINDOW_ID` counter to
/// ensure no collision with Rust-created windows.
///
/// Currently unused — reserved for future when `OnWindowNewResult` carries
/// a pre-generated window ID for ArkTS-side sub-window creation.
#[allow(dead_code)]
pub fn generate_window_id() -> i64 {
    NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst)
}

/// Creates a new OS-level window on OpenHarmony.
///
/// Uses `WindowCreateParams` to pass all window attributes (geometry, decorations,
/// transparent, background_color) in a single struct, avoiding signature bloat
/// as Phase 2/3 add more parameters.
///
/// Pre-allocates a unique window ID, then fires a TSFN to trigger async sub-window
/// creation on the ArkTS main thread (fire-and-forget). The sub-window is guaranteed
/// to be ready before the webview bridge create arrives, since both operations are
/// serialized on the ArkTS UI thread and createSubWindow is dispatched first.
pub fn create_os_window(params: WindowCreateParams) -> napi_ohos::Result<i64> {
    let id = NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst);
    crate::debug!("create_os_window: Pre-allocated window ID: {}", id);

    let tsfn = match TSFN_CREATE_SUB_WINDOW.get() {
        Some(tsfn) => tsfn,
        None => {
            crate::error!(
                "create_os_window: TSFN not initialized (register_create_sub_window_tsfn not called)"
            );
            return Err(Error::from_reason("create_sub_window TSFN not initialized"));
        }
    };

    let status = tsfn.call(
        (
            params.name,
            params.native_module_name,
            id,
            params.width,
            params.height,
            params.x,
            params.y,
            params.display_id,
            params.decorations,
            params.transparent,
            params.background_color,
        ),
        ThreadsafeFunctionCallMode::NonBlocking,
    );

    if status != Status::Ok {
        crate::error!("create_os_window: TSFN dispatch failed: {:?}", status);
        return Err(Error::from_reason(format!(
            "TSFN call failed: {:?}",
            status
        )));
    }

    crate::debug!(
        "create_os_window: Dispatched ArkTS createSubWindow for ID: {}",
        id
    );
    Ok(id)
}

// ─── TSFN for cross-thread vibrancy calls (threadsafe, no main-thread Env needed) ───
// Fire-and-forget (NonBlocking, no return value wait): applyWindowBlur queues pendingBlurs
// (build-time inject via registerController) or calls setAllWebviewsBlurRadius (runtime
// modifier refresh), both idempotent, so no synchronous result needed.

// ─── TSFN for cross-thread sub-window creation (fire-and-forget) ───
// ArkTS registers WindowManager.createSubWindow wrapper via register_create_sub_window_tsfn
// during ProcessInitializer.initialize(). create_os_window calls this TSFN to trigger
// async sub-window creation on the ArkTS main thread, returning the pre-allocated ID
// immediately without waiting for ArkTS to finish (the sub-window is guaranteed to be
// ready before the webview bridge create arrives, since both are serialized on the
// ArkTS UI thread event loop and createSubWindow is dispatched first).
type CreateSubWindowParams = (
    String,
    Option<String>,
    i64,
    i32,
    i32,
    i32,
    i32,
    Option<i64>,
    bool,
    bool,
    Option<u32>,
);
type CreateSubWindowTsfn =
    ThreadsafeFunction<CreateSubWindowParams, (), FnArgs<(Object<'static>,)>, Status, false>;
static TSFN_CREATE_SUB_WINDOW: OnceLock<CreateSubWindowTsfn> = OnceLock::new();

/// Register the ArkTS `createSubWindow` wrapper as a ThreadsafeFunction.
///
/// Called from `ProcessInitializer.initialize()` after native modules are loaded.
/// The ArkTS wrapper is an arrow function that captures `WindowManager.getInstance()`
/// and calls `createSubWindow(config)`, returning a `Promise<number>`.
///
/// After registration, `create_os_window` can fire-and-forget sub-window creation
/// from any thread (TSFN is threadsafe).
#[napi(ts_args_type = "createFn: (config: ESObject) => Promise<number>")]
pub fn register_create_sub_window_tsfn(
    _env: Env,
    create_fn: Function<'static, Object<'static>, ()>,
) -> Result<()> {
    if TSFN_CREATE_SUB_WINDOW.get().is_some() {
        crate::info!("create_sub_window TSFN already registered");
        return Ok(());
    }
    let tsfn = create_fn
        .build_threadsafe_function::<CreateSubWindowParams>()
        .callee_handled::<false>()
        .build_callback(move |ctx: ThreadsafeCallContext<CreateSubWindowParams>| {
            build_create_sub_window_args(ctx.env, ctx.value).map(|args| FnArgs { data: args })
        })?;
    let _ = TSFN_CREATE_SUB_WINDOW.set(tsfn);
    crate::info!("Registered create_sub_window TSFN");
    Ok(())
}

/// TSFN callback helper (runs on ArkTS main thread).
/// Builds a WindowConfig Object from the flattened parameter tuple.
fn build_create_sub_window_args(
    env: Env,
    value: CreateSubWindowParams,
) -> Result<(Object<'static>,)> {
    let (
        name,
        native_module_name,
        window_id,
        width,
        height,
        x,
        y,
        display_id,
        decorations,
        transparent,
        bg_color,
    ) = value;
    let mut config = Object::new(&env)?;
    config.set("name", name)?;
    if let Some(module_name) = native_module_name {
        config.set("nativeModuleName", module_name)?;
    }
    let arkts_window_id = u32::try_from(window_id)
        .map_err(|_| Error::from_reason("Sub-window ID exceeds ArkTS window ID range"))?;
    config.set("windowId", arkts_window_id)?;
    config.set("width", width)?;
    config.set("height", height)?;
    config.set("x", x)?;
    config.set("y", y)?;
    if let Some(display_id) = display_id {
        config.set("displayId", display_id)?;
    }
    config.set("decorations", decorations)?;
    config.set("transparent", transparent)?;
    if let Some(color) = bg_color {
        config.set("backgroundColor", color)?;
    }
    Ok((config,))
}

// ─── Group A: fullscreen ──────────────────────────────────────
// Multi-arg (2+) parameters must be wrapped with FnArgs (a bare tuple is
// passed as a single argument; see napi-ohos JsValuesTupleIntoVec blanket
// impl). Single-arg func.call(id) is unaffected.

/// Allocates the next global window ID without creating a window.
///
/// Used by the windowing backend when a subsequent UIAbility is created: the windowing backend
/// pre-allocates an ID, passes it to the new EntryAbility instance via
/// `want.parameters`, then calls `start_ui_ability`. The new instance's
/// `onWindowStageCreate` registers its WindowStage against this ID via
/// `register_ui_ability_stage`.
pub fn next_window_id() -> i64 {
    NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst)
}

/// Global record of the last windowId reported by a subsequent EntryAbility
/// instance via `register_ui_ability_stage`. Used by automated tests
/// (get_last_ui_ability_window_id command) to verify that want.parameters
/// survived the startAbility call to the new instance.
static LAST_UI_ABILITY_WINDOW_ID: AtomicI64 = AtomicI64::new(-1);

/// NAPI: Called by the new EntryAbility instance's `onWindowStageCreate` (via
/// ArkTS `WindowManager.registerUIAbilityStage`) to report the windowId
/// it received from want.parameters. Records the id globally so automated tests
/// can poll `get_last_ui_ability_window_id` and verify want-parameter forwarding.
#[napi]
pub fn register_ui_ability_stage(window_id: i64) {
    crate::info!(
        "register_ui_ability_stage: id={} (ArkTS-side registration triggered replay)",
        window_id
    );
    LAST_UI_ABILITY_WINDOW_ID.store(window_id, Ordering::SeqCst);
}

/// Reads the last windowId reported by a subsequent instance. Returns -1 if no
/// subsequent instance has registered yet. Used by automated tests.
#[napi]
pub fn get_last_ui_ability_window_id() -> i64 {
    LAST_UI_ABILITY_WINDOW_ID.load(Ordering::SeqCst)
}

// ─── Cursor grab ─────────────────────────────────────────────────────────────
// Cursor lock is pure NDK FFI (OH_WindowManager_LockCursor/UnlockCursor,
// libnative_window_manager.so, API 22+) via the crates.io
// `ohos-window-manager-binding` crate (ohos-rs binding family, PR #82
// review). Re-exported here so `openharmony_ability::window::set_cursor_grab`
// (tao's call path) and the crate-root glob (`pub use window::*`) both keep
// resolving.
mod cursor_grab;
pub use cursor_grab::{set_cursor_grab, CursorGrabError};
