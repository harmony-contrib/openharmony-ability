//! Cursor grab (mouse cursor lock) — facade over the crates.io
//! `ohos-window-manager-binding` crate (ohos-rs binding family).
//!
//! `OH_WindowManager_LockCursor` / `OH_WindowManager_UnlockCursor` are pure
//! NDK C APIs against `libnative_window_manager.so` (oh_window.h, @since 22,
//! permission `ohos.permission.LOCK_WINDOW_CURSOR` / normal / system_grant) —
//! no ArkTS bridge involvement. No ArkTS API exists for cursor locking.
//!
//! The binding crate links `libnative_window_manager.so` at load time, so the
//! pre-binding dlopen/dlsym probe is replaced with an explicit API-version
//! gate: below API 22 the system does not export the symbols, and calling
//! them would abort at PLT resolution instead of returning an error — the
//! gate is what keeps `compatibleSdkVersion` 12 builds degrading gracefully
//! (`NotSupported`) on older devices. `version::init()` runs during ability
//! initialization, before any bridge command — hence before any cursor-grab
//! call — can arrive, so the gate is authoritative on the real call path.
//!
//! Ported from upstream PR#45 (50d3f00). Unlike upstream, this port takes the
//! REAL OHOS window id directly. Upstream resolved the tao window id → real id
//! internally via the old ArkHelper channel (deleted in the pluginize
//! refactor). The ability crate cannot call the plugin-window facade itself
//! (dependency direction: plugin-window → ability), so tao resolves the real
//! id via the bridge (`get-real-window-id` action) before calling
//! `set_cursor_grab` (design D3.7, openspec upstream-ohdev-rebase-window-ops).

use crate::version;

/// WindowManager C API error code for "capability not supported" (oh_window_comm.h).
const WM_ERRORCODE_DEVICE_NOT_SUPPORTED: i64 = 801;
/// WindowManager C API error code for "window state abnormal" (oh_window_comm.h).
const WM_ERRORCODE_STATE_ABNORMAL: i64 = 1300002;

/// First OpenHarmony base API level that exports the cursor lock symbols
/// (oh_window.h `@since 22`).
const CURSOR_LOCK_API_LEVEL: i32 = 22;

/// Typed error for `set_cursor_grab` — tao maps `NotSupported` to
/// `ExternalError::NotSupported` (pre-change behavior on unsupported devices)
/// and the other variants to `ExternalError::Os`.
#[derive(Debug)]
pub enum CursorGrabError {
    /// System does not support cursor lock: API version below 22, or the FFI
    /// call returned 801 (DEVICE_NOT_SUPPORTED).
    NotSupported,
    /// FFI error code: 201 (no permission), 1300002 (window state abnormal),
    /// 1300003 (window manager service abnormal), or any other nonzero code.
    OsCode(i32),
    /// Caller-provided real window id is invalid (≤ 0), or the binding crate
    /// returned a non-code error.
    Bridge(String),
}

impl std::fmt::Display for CursorGrabError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CursorGrabError::NotSupported => {
                let base = "cursor lock not supported on this device";
                let sdk = version::sdk_api_version();
                if sdk > 0 && sdk < CURSOR_LOCK_API_LEVEL {
                    write!(
                        f,
                        "{base} (sdk api version {sdk} < {CURSOR_LOCK_API_LEVEL})"
                    )
                } else {
                    write!(f, "{base}")
                }
            }
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
    cursor_grab_impl(real_window_id, grab)
}

fn cursor_grab_impl(real_window_id: i32, grab: bool) -> std::result::Result<(), CursorGrabError> {
    if version::sdk_api_version() < CURSOR_LOCK_API_LEVEL {
        return Err(CursorGrabError::NotSupported);
    }
    let window = ohos_window_manager_binding::Window::from_id(real_window_id);
    let result = if grab {
        window.lock_cursor(true)
    } else {
        window.unlock_cursor()
    };
    match result {
        Ok(()) => Ok(()),
        Err(e) => match e.code() {
            Some(WM_ERRORCODE_DEVICE_NOT_SUPPORTED) => Err(CursorGrabError::NotSupported),
            // Unlock is idempotent: the system auto-releases the lock on focus
            // loss, so unlocking an already-unlocked window returns
            // STATE_ABNORMAL (1300002). Treat that as success — matches
            // Windows, where clearing the ClipCursor flag when not grabbed
            // succeeds silently.
            Some(WM_ERRORCODE_STATE_ABNORMAL) if !grab => Ok(()),
            Some(code) => Err(CursorGrabError::OsCode(code as i32)),
            None => Err(CursorGrabError::Bridge(e.to_string())),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_covers_all_variants() {
        assert_eq!(
            CursorGrabError::OsCode(1300002).to_string(),
            "window manager error code 1300002"
        );
        assert_eq!(
            CursorGrabError::Bridge("lookup failed".into()).to_string(),
            "cursor grab bridge failure: lookup failed"
        );
        let not_supported = CursorGrabError::NotSupported.to_string();
        assert!(
            not_supported.starts_with("cursor lock not supported on this device"),
            "unexpected NotSupported message: {not_supported}"
        );
    }

    #[test]
    fn invalid_window_id_is_a_bridge_error() {
        assert!(matches!(
            set_cursor_grab(0, true),
            Err(CursorGrabError::Bridge(_))
        ));
        assert!(matches!(
            set_cursor_grab(-3, false),
            Err(CursorGrabError::Bridge(_))
        ));
    }

    // On an API < 22 device the version gate fires before any FFI call. On
    // API >= 22 devices the gate passes and the FFI path is exercised by the
    // e2e suite (examples/api `window.setCursorGrab`) — not here, to avoid
    // locking the test runner's cursor.
    #[test]
    fn ohos_below_api22_returns_not_supported_without_ffi() {
        if version::sdk_api_version() < CURSOR_LOCK_API_LEVEL {
            assert!(matches!(
                set_cursor_grab(1, true),
                Err(CursorGrabError::NotSupported)
            ));
        }
    }
}
