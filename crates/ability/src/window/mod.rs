use napi_ohos::bindgen_prelude::*;
use crate::{get_helper, get_main_thread_env};
use std::sync::atomic::{AtomicI64, Ordering};

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

/// Creates a new OS-level window on OpenHarmony.
///
/// Uses `WindowCreateParams` to pass all window attributes (geometry, decorations,
/// transparent, background_color) in a single struct, avoiding signature bloat
/// as Phase 2/3 add more parameters.
pub fn create_os_window(params: WindowCreateParams) -> napi_ohos::Result<i64> {
    // 1. Synchronously allocate a unique ID
    let id = NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst);
    crate::info!("Pre-allocated window ID: {}", id);

    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func = match obj.get_named_property::<Function<'_, Object, Unknown>>("createOSWindow") {
                Ok(f) => f,
                Err(e) => {
                    crate::error!("Property 'createOSWindow' NOT FOUND on helper: {:?}", e);
                    return Err(e);
                }
            };

            crate::info!("Successfully found createOSWindow, building config object...");

            // 2. Create config object with all parameters
            let mut config = Object::new(env)?;
            config.set("name", params.name)?;
            // Note: "type" field is deprecated and no longer sent (OHOS createSubWindow only uses name)
            config.set("windowId", id)?;
            config.set("width", params.width)?;
            config.set("height", params.height)?;
            config.set("x", params.x)?;
            config.set("y", params.y)?;
            // Phase 2: decorations
            config.set("decorations", params.decorations)?;
            // Phase 3: transparent + backgroundColor
            config.set("transparent", params.transparent)?;
            if let Some(color) = params.background_color {
                config.set("backgroundColor", color)?;
            }

            crate::info!("Calling ArkTS with config object...");

            // 3. Call ArkTS and return the ID on success
            match func.call(config) {
                Ok(_) => {
                    crate::info!("ArkTS call succeeded, returning ID: {}", id);
                    return Ok(id);
                }
                Err(e) => {
                    crate::error!("ArkTS call failed: {:?}", e);
                    return Err(e);
                }
            }
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Sets window decorations (title bar visibility) at runtime via NAPI.
///
/// Calls ArkTS `setWindowDecorations(windowId, decorations)` handler which
/// updates LocalStorage → FloatPage `@LocalStorageProp` reactive re-render.
///
/// Phase 2 implementation.
pub fn set_window_decorations(window_id: i64, decorations: bool) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func = obj.get_named_property::<Function<'_, (i64, bool), ()>>("setWindowDecorations")?;
            func.call((window_id, decorations))?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Sets window background color at runtime via NAPI.
///
/// Calls ArkTS `setWindowBackgroundColor(windowId, color)` handler which
/// calls OHOS `window.Window.setWindowBackgroundColor('#AARRGGBB')`.
///
/// `color` is in `0xAARRGGBB` format (e.g., `0x00000000` = fully transparent).
///
/// Phase 3 implementation.
pub fn set_window_background_color(window_id: i64, color: u32) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func = obj.get_named_property::<Function<'_, (i64, u32), ()>>("setWindowBackgroundColor")?;
            func.call((window_id, color))?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}
