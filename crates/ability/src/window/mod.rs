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
            window_type: 0,
            width: 800,
            height: 600,
            x: 100,
            y: 100,
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
            id,
            params.width,
            params.height,
            params.x,
            params.y,
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
type CreateSubWindowTsfn = ThreadsafeFunction<
    (String, i64, i32, i32, i32, i32, bool, bool, Option<u32>),
    (),
    FnArgs<(Object<'static>,)>,
    Status,
    false,
>;
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
        .build_threadsafe_function::<(String, i64, i32, i32, i32, i32, bool, bool, Option<u32>)>()
        .callee_handled::<false>()
        .build_callback(
            move |ctx: ThreadsafeCallContext<(
                String,
                i64,
                i32,
                i32,
                i32,
                i32,
                bool,
                bool,
                Option<u32>,
            )>| {
                build_create_sub_window_args(ctx.env, ctx.value).map(|args| FnArgs { data: args })
            },
        )?;
    let _ = TSFN_CREATE_SUB_WINDOW.set(tsfn);
    crate::info!("Registered create_sub_window TSFN");
    Ok(())
}

/// TSFN callback helper (runs on ArkTS main thread).
/// Builds a WindowConfig Object from the flattened parameter tuple.
fn build_create_sub_window_args(
    env: Env,
    value: (String, i64, i32, i32, i32, i32, bool, bool, Option<u32>),
) -> Result<(Object<'static>,)> {
    let (name, window_id, width, height, x, y, decorations, transparent, bg_color) = value;
    let mut config = Object::new(&env)?;
    config.set("name", name)?;
    config.set("windowId", window_id)?;
    config.set("width", width)?;
    config.set("height", height)?;
    config.set("x", x)?;
    config.set("y", y)?;
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

// ─── Group F: cursor grab (OH_WindowManager_LockCursor/UnlockCursor, NDK C API 22+) ───
//
// Ported from upstream PR#45 (50d3f00). Pure FFI — no ArkTS bridge involvement.
//
// No ArkTS API exists for cursor locking — the only public surface is the NDK
// C API in libnative_window_manager.so (oh_window.h, @since 22, permission
// ohos.permission.LOCK_WINDOW_CURSOR / normal / system_grant). The library is
// resolved lazily via dlopen+dlsym instead of a static `#[link]`:
// compatibleSdkVersion is API 12 and system images below API 22 do not export
// these symbols, so a load-time link would prevent the app from starting on
// older devices. Symbol presence doubles as the version guard
// (dlsym null ⇒ device below API 22 ⇒ NotSupported).
//
// Unlike upstream, this port takes the REAL OHOS window id directly. Upstream
// resolved the tao window id → real id internally via the old ArkHelper channel
// (deleted in the pluginize refactor). The ability crate cannot call the
// plugin-window facade itself (dependency direction: plugin-window → ability),
// so tao resolves the real id via the bridge (`get-real-window-id` action)
// before calling this function (design D3.7, openspec
// upstream-ohdev-rebase-window-ops).

type LockCursorFn = unsafe extern "C" fn(window_id: i32, is_cursor_follow_movement: bool) -> i32;
type UnlockCursorFn = unsafe extern "C" fn(window_id: i32) -> i32;

struct CursorLockApi {
    lock_cursor: LockCursorFn,
    unlock_cursor: UnlockCursorFn,
}

/// WindowManager C API error code for "capability not supported" (oh_window_comm.h).
const WM_ERRORCODE_DEVICE_NOT_SUPPORTED: i32 = 801;
/// WindowManager C API error code for "window state abnormal" (oh_window_comm.h).
const WM_ERRORCODE_STATE_ABNORMAL: i32 = 1300002;

static CURSOR_LOCK_API: OnceLock<Option<CursorLockApi>> = OnceLock::new();

extern "C" {
    fn dlopen(filename: *const std::ffi::c_char, flags: std::ffi::c_int) -> *mut std::ffi::c_void;
    fn dlsym(
        handle: *mut std::ffi::c_void,
        symbol: *const std::ffi::c_char,
    ) -> *mut std::ffi::c_void;
}

/// Resolves the cursor lock C API once per process; `None` when the system
/// does not provide it (API < 22). The handle is intentionally never closed —
/// the library stays loaded for the process lifetime.
fn cursor_lock_api() -> Option<&'static CursorLockApi> {
    CURSOR_LOCK_API
        .get_or_init(|| unsafe {
            // RTLD_NOW | RTLD_LOCAL = 2 on OHOS musl.
            let handle = dlopen(
                b"libnative_window_manager.so\0".as_ptr() as *const std::ffi::c_char,
                2,
            );
            if handle.is_null() {
                crate::warn!("[ohos-window] dlopen libnative_window_manager.so failed (library missing/broken) — cursor grab unsupported");
                return None;
            }
            let lock = dlsym(handle, b"OH_WindowManager_LockCursor\0".as_ptr() as *const std::ffi::c_char);
            let unlock = dlsym(handle, b"OH_WindowManager_UnlockCursor\0".as_ptr() as *const std::ffi::c_char);
            if lock.is_null() || unlock.is_null() {
                crate::warn!("[ohos-window] OH_WindowManager_LockCursor/UnlockCursor not exported — cursor grab unsupported");
                return None;
            }
            Some(CursorLockApi {
                lock_cursor: std::mem::transmute::<*mut std::ffi::c_void, LockCursorFn>(lock),
                unlock_cursor: std::mem::transmute::<*mut std::ffi::c_void, UnlockCursorFn>(unlock),
            })
        })
        .as_ref()
}

/// Typed error for `set_cursor_grab` — tao maps `NotSupported` to
/// `ExternalError::NotSupported` (pre-change behavior on unsupported devices)
/// and the other variants to `ExternalError::Os`.
#[derive(Debug)]
pub enum CursorGrabError {
    /// System does not support cursor lock: dlsym failed (API < 22) or the
    /// FFI call returned 801 (DEVICE_NOT_SUPPORTED).
    NotSupported,
    /// FFI error code: 201 (no permission), 1300002 (window state abnormal),
    /// 1300003 (window manager service abnormal), or any other nonzero code.
    OsCode(i32),
    /// Caller-provided real window id is invalid (≤ 0), or the bridge lookup
    /// upstream failed before reaching this function.
    Bridge(String),
}

impl std::fmt::Display for CursorGrabError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CursorGrabError::NotSupported => write!(f, "cursor lock not supported on this device"),
            CursorGrabError::OsCode(code) => write!(f, "window manager error code {code}"),
            CursorGrabError::Bridge(reason) => write!(f, "cursor grab bridge failure: {reason}"),
        }
    }
}

/// Locks/unlocks the mouse cursor to a window (tao `set_cursor_grab`).
///
/// `real_window_id` is the REAL OHOS window instance id (from
/// `win.getWindowProperties().id`), resolved by tao via the plugin-window
/// bridge before calling — see the module-level comment above.
///
/// Lock uses confined-follow mode (`isCursorFollowMovement=true`, cursor keeps
/// moving within the window area — matches Windows ClipCursor semantics). The
/// lock only takes effect while the window is focused; the system releases it
/// automatically on focus loss. Unlock restores free cursor movement.
///
/// Pure FFI — safe from any thread (no NAPI env access). Returns a typed error
/// (explicit `std::result::Result`) so tao can map `NotSupported` vs OS errors
/// without string matching.
pub fn set_cursor_grab(
    real_window_id: i32,
    grab: bool,
) -> std::result::Result<(), CursorGrabError> {
    if real_window_id <= 0 {
        return Err(CursorGrabError::Bridge(format!(
            "invalid real window id {real_window_id}"
        )));
    }
    let api = cursor_lock_api().ok_or(CursorGrabError::NotSupported)?;
    let code = if grab {
        unsafe { (api.lock_cursor)(real_window_id, true) }
    } else {
        unsafe { (api.unlock_cursor)(real_window_id) }
    };
    match code {
        0 => Ok(()),
        // Unlock is idempotent: the system auto-releases the lock on focus
        // loss, so unlocking an already-unlocked window returns STATE_ABNORMAL
        // (1300002). Treat that as success — matches Windows, where clearing
        // the ClipCursor flag when not grabbed succeeds silently.
        WM_ERRORCODE_STATE_ABNORMAL if !grab => Ok(()),
        WM_ERRORCODE_DEVICE_NOT_SUPPORTED => Err(CursorGrabError::NotSupported),
        other => Err(CursorGrabError::OsCode(other)),
    }
}
