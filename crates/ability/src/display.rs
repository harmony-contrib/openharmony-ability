//! Multi-display enumeration for the windowing backend (issue
//! Eulogizethesun/tauri#106).
//!
//! Two data sources are merged:
//!
//! 1. **Display list** (id/name/size/refresh/scale) from the NDK C API
//!    `OH_NativeDisplayManager_CreateAllDisplays` (`libnative_display_manager.so`,
//!    @since 14). compatibleSdkVersion is API 12, so the symbols are resolved
//!    lazily via dlopen+dlsym (same pattern as the cursor-grab C API in
//!    [`crate::window`]) — a load-time link would keep the app from starting on
//!    API 12/13 devices. Symbol absence ⇒ single-display fallback from the
//!    default-display queries.
//!
//! 2. **Positions** (x/y) from the ArkTS `display.getAllDisplays()` +
//!    `Display.x`/`Display.y` (@since 19, optional fields — `undefined` below
//!    API 19). The C `NativeDisplayManager_DisplayInfo` struct has NO x/y
//!    fields, so positions can only come from ArkTS. `NativeAbility.ets`
//!    pushes the whole layout via the `set_display_layout` NAPI function at
//!    window-stage creation and on every `display.on('add'|'remove'|'change')`
//!    event; a missing/absent entry degrades to (0,0).

use std::ffi::c_char;
use std::sync::{Mutex, OnceLock};

use napi_derive_ohos::napi;
use ohos_display_binding::{
    default_display_height, default_display_id, default_display_refresh_rate,
    default_display_scaled_density, default_display_virtual_pixel_ratio, default_display_width,
};

// ─── FFI (api-14 layout of libnative_display_manager.so) ────────────────────
//
// Layout copied verbatim from the `ohos-display-sys` 0.1.3 api-14 bindings —
// the struct is @since 14 and stable from then on, and the array returned by
// `OH_NativeDisplayManager_CreateAllDisplays` is indexed by this layout, so
// every field (including the trailing hdr/colorSpace pointers we never read)
// must be present.

#[repr(C)]
#[allow(non_snake_case)]
struct NativeDisplayManager_DisplayHdrFormat {
    hdrFormatLength: u32,
    hdrFormats: *mut u32,
}

#[repr(C)]
#[allow(non_snake_case)]
struct NativeDisplayManager_DisplayColorSpace {
    colorSpaceLength: u32,
    colorSpaces: *mut u32,
}

#[repr(C)]
#[allow(non_snake_case)]
struct NativeDisplayManager_DisplayInfo {
    id: u32,
    name: [c_char; 33],
    isAlive: bool,
    width: i32,
    height: i32,
    physicalWidth: i32,
    physicalHeight: i32,
    refreshRate: u32,
    availableWidth: u32,
    availableHeight: u32,
    densityDPI: f32,
    densityPixels: f32,
    scaledDensity: f32,
    xDPI: f32,
    yDPI: f32,
    rotation: u32,
    state: u32,
    orientation: u32,
    hdrFormat: *mut NativeDisplayManager_DisplayHdrFormat,
    colorSpace: *mut NativeDisplayManager_DisplayColorSpace,
}

#[repr(C)]
#[allow(non_snake_case)]
struct NativeDisplayManager_DisplaysInfo {
    displaysLength: u32,
    displaysInfo: *mut NativeDisplayManager_DisplayInfo,
}

type CreateAllDisplaysFn = unsafe extern "C" fn(*mut *mut NativeDisplayManager_DisplaysInfo) -> u32;
type DestroyAllDisplaysFn = unsafe extern "C" fn(*mut NativeDisplayManager_DisplaysInfo);

struct AllDisplaysApi {
    create_all_displays: CreateAllDisplaysFn,
    destroy_all_displays: DestroyAllDisplaysFn,
}

extern "C" {
    fn dlopen(filename: *const c_char, flags: std::ffi::c_int) -> *mut std::ffi::c_void;
    fn dlsym(handle: *mut std::ffi::c_void, symbol: *const c_char) -> *mut std::ffi::c_void;
}

static ALL_DISPLAYS_API: OnceLock<Option<AllDisplaysApi>> = OnceLock::new();

/// Resolve `OH_NativeDisplayManager_CreateAllDisplays`/`DestroyAllDisplays`
/// once per process; `None` on API < 14 (symbol missing). The handle is
/// intentionally never closed — the library stays loaded for the process
/// lifetime (same as [`crate::window`]'s cursor-grab resolver).
fn all_displays_api() -> Option<&'static AllDisplaysApi> {
    ALL_DISPLAYS_API
        .get_or_init(|| unsafe {
            // RTLD_NOW | RTLD_LOCAL = 2 on OHOS musl.
            let handle = dlopen(c"libnative_display_manager.so".as_ptr(), 2);
            if handle.is_null() {
                crate::warn!(
                    "[ohos-display] dlopen libnative_display_manager.so failed — \
                     single-display fallback"
                );
                return None;
            }
            let create = dlsym(
                handle,
                c"OH_NativeDisplayManager_CreateAllDisplays".as_ptr(),
            );
            let destroy = dlsym(
                handle,
                c"OH_NativeDisplayManager_DestroyAllDisplays".as_ptr(),
            );
            if create.is_null() || destroy.is_null() {
                crate::warn!(
                    "[ohos-display] OH_NativeDisplayManager_CreateAllDisplays not exported \
                     (API < 14?) — single-display fallback"
                );
                return None;
            }
            Some(AllDisplaysApi {
                create_all_displays: std::mem::transmute::<
                    *mut std::ffi::c_void,
                    CreateAllDisplaysFn,
                >(create),
                destroy_all_displays: std::mem::transmute::<
                    *mut std::ffi::c_void,
                    DestroyAllDisplaysFn,
                >(destroy),
            })
        })
        .as_ref()
}

// ─── Position overlay (pushed from ArkTS) ───────────────────────────────────

/// Display positions (id, x, y) in physical pixels, replaced wholesale by
/// `set_display_layout`. `Vec::new()` is const-constructible so a plain
/// `Mutex` static works (same as `PENDING_WINDOW_STATUS`).
static DISPLAY_POSITIONS: Mutex<Vec<(u32, i32, i32)>> = Mutex::new(Vec::new());

/// NAPI function called from ArkTS with the full display layout as JSON
/// (`[[id, x, y], ...]`, physical px). Pushed at window-stage creation and on
/// `display.on('add'|'remove'|'change')`. Replaces the previous layout so
/// unplugged displays disappear. `x`/`y` are 0 when the device is below API 19
/// (`Display.x`/`y` undefined) — no worse than the pre-fix constant (0,0).
#[napi]
pub fn set_display_layout(layout_json: String) {
    let layout: Vec<(u32, i32, i32)> = match serde_json::from_str(&layout_json) {
        Ok(layout) => layout,
        Err(e) => {
            crate::warn!("[ohos-display] set_display_layout parse failed: {e}");
            return;
        }
    };
    match DISPLAY_POSITIONS.lock() {
        Ok(mut positions) => *positions = layout,
        Err(poisoned) => *poisoned.into_inner() = layout,
    }
}

fn position_of(display_id: u32) -> Option<(i32, i32)> {
    DISPLAY_POSITIONS.lock().ok().and_then(|positions| {
        positions
            .iter()
            .find(|(id, _, _)| *id == display_id)
            .map(|&(_, x, y)| (x, y))
    })
}

// --- Virtual pixel ratio (openspec ohos-webview-bounds, #198) ---------------

/// Ratio returned when the display binding is unavailable or reports nothing
/// usable -- the "physical px == vp" identity the desktop baseline and the
/// previous `to_logical::<f64>(1.0)` behavior are calibrated against.
const FALLBACK_VIRTUAL_PIXEL_RATIO: f32 = 1.0;

/// Value guard for the binding's raw virtual pixel ratio: keeps a positive
/// finite ratio, degrades everything else (0 on error paths, non-finite
/// garbage) to the 1.0 fallback. Split from [`virtual_pixel_ratio`] so the
/// degradation contract is UT-able without touching the display C API
/// (device-only).
fn sanitize_vp(vp: f32) -> f32 {
    if vp > 0.0 && vp.is_finite() {
        vp
    } else {
        FALLBACK_VIRTUAL_PIXEL_RATIO
    }
}

/// The default display's virtual pixel ratio (physical px per logical vp) for
/// the bounds logical<->physical conversion (openspec ohos-webview-bounds, #198).
///
/// Thin wrapper over the existing `ohos_display_binding` C-API binding
/// `default_display_virtual_pixel_ratio() -> f32` (same family as
/// [`default_display_scaled_density`], no new NAPI wire, no ArkTS surface).
/// A binding value <= 0 (early calls / unsupported device) degrades to the 1.0
/// identity fallback via `sanitize_vp`. Never blocks; the binding's own
/// error signaling is a non-zero return code, not a blocking call.
pub fn virtual_pixel_ratio() -> f32 {
    sanitize_vp(default_display_virtual_pixel_ratio())
}

// ─── Public API ─────────────────────────────────────────────────────────────

/// One display snapshot, consumed by tao's `MonitorHandle` accessors.
#[derive(Clone, Debug, PartialEq)]
pub struct DisplaySnapshot {
    /// OHOS display id (`OH_NativeDisplayManager_GetDefaultDisplayId` domain).
    pub id: u32,
    /// Display name reported by the display manager (empty when unknown).
    pub name: String,
    /// Top-left offset in the global display coordinate space (ArkTS
    /// `Display.x`/`y`; (0,0) when unknown — API < 19 or not yet pushed).
    pub x: i32,
    /// Top-left Y offset in the global display coordinate space.
    pub y: i32,
    /// Physical size in pixels.
    pub width: u32,
    /// Physical height in pixels (0 when not reported by the display API).
    pub height: u32,
    /// Screen refresh rate in Hz (0 when not reported).
    pub refresh_rate: u32,
    /// `scaledDensity` — the same source `OpenHarmonyApp::scale()` uses for
    /// the default display.
    pub scale: f64,
}

/// Enumerate all displays. Falls back to a single (default) display snapshot
/// when the C API is unavailable (API < 14) or returns nothing; the fallback
/// can still carry an ArkTS-pushed position for the default display.
pub fn all_displays() -> Vec<DisplaySnapshot> {
    if let Some(api) = all_displays_api() {
        let mut info_ptr: *mut NativeDisplayManager_DisplaysInfo = std::ptr::null_mut();
        let ret = unsafe { (api.create_all_displays)(&mut info_ptr) };
        if ret != 0 {
            crate::warn!("[ohos-display] CreateAllDisplays failed with code {ret}");
            return default_display_fallback();
        }
        if info_ptr.is_null() {
            return default_display_fallback();
        }
        let snapshots = unsafe {
            let info = &*info_ptr;
            let len = info.displaysLength as usize;
            let base = info.displaysInfo;
            if base.is_null() || len == 0 {
                Vec::new()
            } else {
                (0..len)
                    .map(|i| {
                        let raw = &*base.add(i);
                        let (x, y) = position_of(raw.id).unwrap_or((0_i32, 0_i32));
                        DisplaySnapshot {
                            id: raw.id,
                            name: c_name_to_string(&raw.name),
                            x,
                            y,
                            width: raw.width.max(0_i32) as u32,
                            height: raw.height.max(0_i32) as u32,
                            refresh_rate: raw.refreshRate,
                            scale: raw.scaledDensity as f64,
                        }
                    })
                    .collect()
            }
        };
        unsafe { (api.destroy_all_displays)(info_ptr) };
        if snapshots.is_empty() {
            default_display_fallback()
        } else {
            snapshots
        }
    } else {
        default_display_fallback()
    }
}

/// Single-snapshot fallback built from the default-display queries (API 12).
/// Width/height may be 0 when even those fail — tao's `MonitorHandle::size()`
/// then degrades to the content-rect fallback (pre-fix behavior).
fn default_display_fallback() -> Vec<DisplaySnapshot> {
    let id = default_display_id() as u32;
    let (x, y) = position_of(id).unwrap_or((0_i32, 0_i32));
    vec![DisplaySnapshot {
        id,
        name: "OpenHarmony Device".to_string(),
        x,
        y,
        width: default_display_width().max(0) as u32,
        height: default_display_height().max(0) as u32,
        refresh_rate: default_display_refresh_rate(),
        scale: default_display_scaled_density() as f64,
    }]
}

/// The default (primary) display id.
pub fn default_display() -> u32 {
    default_display_id() as u32
}

/// Read the fixed-size C char array as a Rust String (NUL-terminated).
fn c_name_to_string(raw: &[c_char]) -> String {
    let bytes: Vec<u8> = raw
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// UT for #198: a positive finite binding value passes through unchanged.
    /// # Brief: sanitize 1.0 and 2.5 and assert identity.
    #[test]
    fn ut_sanitize_vp_keeps_positive_finite() {
        assert_eq!(sanitize_vp(1.0), 1.0);
        assert_eq!(sanitize_vp(2.5), 2.5);
    }

    /// UT for #198: a binding value <= 0 (early call / unsupported device)
    /// degrades to the 1.0 identity fallback, per the spec's fallback
    /// scenario ("virtual_pixel_ratio() SHALL return 1.0, no panic").
    /// # Brief: sanitize 0.0, negative, NaN and +/-inf and assert 1.0.
    #[test]
    fn ut_sanitize_vp_falls_back_to_one() {
        assert_eq!(sanitize_vp(0.0), 1.0);
        assert_eq!(sanitize_vp(-1.5), 1.0);
        assert_eq!(sanitize_vp(f32::NAN), 1.0);
        assert_eq!(sanitize_vp(f32::INFINITY), 1.0);
        assert_eq!(sanitize_vp(f32::NEG_INFINITY), 1.0);
    }

    /// UT for #198: the fallback constant is exactly the documented 1.0
    /// identity the desktop baseline is calibrated against.
    /// # Brief: assert the constant value.
    #[test]
    fn ut_fallback_vp_constant_is_one() {
        assert_eq!(FALLBACK_VIRTUAL_PIXEL_RATIO, 1.0);
    }
}
