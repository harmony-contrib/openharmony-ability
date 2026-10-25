//! Window snapshot capture via `OH_WindowManager_Snapshot` (`oh_window.h`, `@since 15`)
//! and `OH_WindowManager_GetWindowProperties`.
//!
//! Pure NDK FFI — safe to call from any thread without N-API `Env` access.
//! Below API 15, the explicit `version::sdk_api_version()` gate returns
//! [`WindowSnapshotError::NotSupported`] without resolving the NDK symbols.

use ohos_image_native_binding::{
    PixelFormat, PixelMap, PixelMapAlphaType, PixelMapInitializationOptions,
};

use crate::version;

/// WindowManager C API error code for "capability not supported" (`oh_window_comm.h`).
const WM_ERRORCODE_DEVICE_NOT_SUPPORTED: i64 = 801;

/// First OpenHarmony API level that exports `OH_WindowManager_Snapshot` and
/// `OH_WindowManager_GetWindowProperties` (`oh_window.h` `@since 15`).
const WINDOW_SNAPSHOT_API_LEVEL: i32 = 15;

/// Captured window pixel buffer and geometry returned by [`snapshot_window`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowSnapshot {
    /// Snapshot pixel width.
    pub width: u32,
    /// Snapshot pixel height.
    pub height: u32,
    /// Window X coordinate in display pixels (`windowRect.posX`).
    pub window_x: i32,
    /// Window Y coordinate in display pixels (`windowRect.posY`).
    pub window_y: i32,
    /// Window width in display pixels (`windowRect.width`).
    pub window_width: u32,
    /// Window height in display pixels (`windowRect.height`).
    pub window_height: u32,
    /// Display ID on which the window resides.
    pub display_id: u32,
    /// Tightly-packed unpremultiplied `RGBA8` pixel data (`width * height * 4` bytes).
    pub rgba: Vec<u8>,
}

/// Typed error for [`snapshot_window`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WindowSnapshotError {
    /// System does not support native window snapshots (API < 15 or error code 801).
    NotSupported,
    /// Window manager FFI error code.
    OsCode(i32),
    /// Invalid window ID, pixelmap initialization failure, or pixel read error.
    PixelMap(String),
}

impl std::fmt::Display for WindowSnapshotError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WindowSnapshotError::NotSupported => {
                let base = "window snapshot not supported on this device";
                let sdk = version::sdk_api_version();
                if sdk > 0 && sdk < WINDOW_SNAPSHOT_API_LEVEL {
                    write!(
                        f,
                        "{base} (sdk api version {sdk} < {WINDOW_SNAPSHOT_API_LEVEL})"
                    )
                } else {
                    write!(f, "{base}")
                }
            }
            WindowSnapshotError::OsCode(code) => write!(f, "window manager error code {code}"),
            WindowSnapshotError::PixelMap(reason) => {
                write!(f, "window snapshot pixelmap error: {reason}")
            }
        }
    }
}

impl std::error::Error for WindowSnapshotError {}

/// Captures a snapshot of a window identified by its real OpenHarmony window ID
/// (`win.getWindowProperties().id`).
///
/// Returns the window's screen rectangle (`window_x`, `window_y`, `window_width`,
/// `window_height`), `display_id`, and tightly-packed unpremultiplied `RGBA8`
/// pixel buffer.
pub fn snapshot_window(
    real_window_id: i32,
) -> std::result::Result<WindowSnapshot, WindowSnapshotError> {
    if real_window_id <= 0 {
        return Err(WindowSnapshotError::PixelMap(format!(
            "invalid real window id {real_window_id}"
        )));
    }
    if version::sdk_api_version() < WINDOW_SNAPSHOT_API_LEVEL {
        return Err(WindowSnapshotError::NotSupported);
    }

    let window = ohos_window_manager_binding::Window::from_id(real_window_id);
    let props = window.properties().map_err(map_wm_error)?;

    let mut pixel_map = create_seed_pixel_map()?;
    window.snapshot(pixel_map.handle()).map_err(map_wm_error)?;

    let info = pixel_map
        .image_info()
        .map_err(|e| WindowSnapshotError::PixelMap(e.to_string()))?;
    let width = info
        .width()
        .map_err(|e| WindowSnapshotError::PixelMap(e.to_string()))?;
    let height = info
        .height()
        .map_err(|e| WindowSnapshotError::PixelMap(e.to_string()))?;
    if width == 0 || height == 0 {
        return Err(WindowSnapshotError::PixelMap(
            "snapshot returned zero-sized image".into(),
        ));
    }
    let row_stride = info
        .row_stride()
        .unwrap_or(width.saturating_mul(4))
        .max(width.saturating_mul(4));
    let pixel_format = info.pixel_format().unwrap_or(PixelFormat::Rgba8888);
    let alpha_type = info.alpha_type().unwrap_or(PixelMapAlphaType::Opaque);

    let rgba = read_pixel_map_rgba(
        &mut pixel_map,
        width,
        height,
        row_stride,
        pixel_format,
        alpha_type,
    )?;

    Ok(WindowSnapshot {
        width,
        height,
        window_x: props.window_rect.x,
        window_y: props.window_rect.y,
        window_width: props.window_rect.width,
        window_height: props.window_rect.height,
        display_id: props.display_id,
        rgba,
    })
}

fn map_wm_error(err: ohos_window_manager_binding::Error) -> WindowSnapshotError {
    match err.code() {
        Some(WM_ERRORCODE_DEVICE_NOT_SUPPORTED) => WindowSnapshotError::NotSupported,
        Some(code) => WindowSnapshotError::OsCode(code as i32),
        None => WindowSnapshotError::PixelMap(err.to_string()),
    }
}

fn create_seed_pixel_map() -> std::result::Result<PixelMap, WindowSnapshotError> {
    let mut options = PixelMapInitializationOptions::new()
        .map_err(|e| WindowSnapshotError::PixelMap(e.to_string()))?;
    options
        .set_width(4)
        .map_err(|e| WindowSnapshotError::PixelMap(e.to_string()))?;
    options
        .set_height(4)
        .map_err(|e| WindowSnapshotError::PixelMap(e.to_string()))?;
    options
        .set_pixel_format(PixelFormat::Rgba8888)
        .map_err(|e| WindowSnapshotError::PixelMap(e.to_string()))?;
    options
        .set_alpha_type(PixelMapAlphaType::Opaque)
        .map_err(|e| WindowSnapshotError::PixelMap(e.to_string()))?;
    let mut seed = [0u8; 4 * 4 * 4];
    PixelMap::create(&mut seed, &mut options)
        .map_err(|e| WindowSnapshotError::PixelMap(e.to_string()))
}

fn read_pixel_map_rgba(
    pixel_map: &mut PixelMap,
    width: u32,
    height: u32,
    row_stride: u32,
    pixel_format: PixelFormat,
    alpha_type: PixelMapAlphaType,
) -> std::result::Result<Vec<u8>, WindowSnapshotError> {
    let row_bytes = (width as usize)
        .checked_mul(4)
        .ok_or_else(|| WindowSnapshotError::PixelMap("snapshot width overflow".into()))?;
    let total_bytes = row_bytes
        .checked_mul(height as usize)
        .ok_or_else(|| WindowSnapshotError::PixelMap("snapshot dimensions overflow".into()))?;

    let mut rgba = vec![0u8; total_bytes];

    if let Ok(base_ptr) = pixel_map.access_pixels() {
        let stride = (row_stride as usize).max(row_bytes);
        let src_ptr = base_ptr.as_ptr() as *const u8;
        for y in 0..(height as usize) {
            let src_row = unsafe { std::slice::from_raw_parts(src_ptr.add(y * stride), row_bytes) };
            let dst_offset = y * row_bytes;
            rgba[dst_offset..dst_offset + row_bytes].copy_from_slice(src_row);
        }
        let _ = pixel_map.unaccess_pixels();
        normalize_pixel_buffer(
            &mut rgba,
            matches!(pixel_format, PixelFormat::Bgra8888),
            alpha_type,
        );
        return Ok(rgba);
    }

    // Fallback to OH_PixelmapNative_ReadPixels if direct memory lock is unavailable.
    let stride = (row_stride as usize).max(row_bytes);
    let alloc_len = stride
        .checked_mul(height as usize)
        .ok_or_else(|| WindowSnapshotError::PixelMap("snapshot stride overflow".into()))?;
    let mut raw_buf = vec![0u8; alloc_len];
    let bytes_read = pixel_map
        .read_pixels(&mut raw_buf)
        .map_err(|e| WindowSnapshotError::PixelMap(e.to_string()))?;

    if bytes_read == total_bytes || stride == row_bytes {
        rgba.copy_from_slice(&raw_buf[..total_bytes]);
    } else {
        for y in 0..(height as usize) {
            let src_offset = y * stride;
            let dst_offset = y * row_bytes;
            rgba[dst_offset..dst_offset + row_bytes]
                .copy_from_slice(&raw_buf[src_offset..src_offset + row_bytes]);
        }
    }
    normalize_pixel_buffer(
        &mut rgba,
        matches!(pixel_format, PixelFormat::Bgra8888),
        alpha_type,
    );
    Ok(rgba)
}

#[allow(clippy::chunks_exact_to_as_chunks)]
fn normalize_pixel_buffer(rgba: &mut [u8], is_bgra: bool, alpha_type: PixelMapAlphaType) {
    let unpremul = matches!(alpha_type, PixelMapAlphaType::Premultiplied);
    if !is_bgra && !unpremul {
        return;
    }
    for px in rgba.chunks_exact_mut(4) {
        if is_bgra {
            px.swap(0, 2);
        }
        if unpremul {
            let a = px[3];
            if a > 0 && a < 255 {
                let a16 = a as u16;
                px[0] = ((px[0] as u16 * 255 + (a16 / 2)) / a16).min(255) as u8;
                px[1] = ((px[1] as u16 * 255 + (a16 / 2)) / a16).min(255) as u8;
                px[2] = ((px[2] as u16 * 255 + (a16 / 2)) / a16).min(255) as u8;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_covers_all_variants() {
        assert_eq!(
            WindowSnapshotError::OsCode(1300002).to_string(),
            "window manager error code 1300002"
        );
        assert_eq!(
            WindowSnapshotError::PixelMap("alloc failed".into()).to_string(),
            "window snapshot pixelmap error: alloc failed"
        );
        assert!(WindowSnapshotError::NotSupported
            .to_string()
            .starts_with("window snapshot not supported on this device"));
    }

    #[test]
    fn invalid_window_id_is_rejected() {
        assert!(matches!(
            snapshot_window(0),
            Err(WindowSnapshotError::PixelMap(_))
        ));
        assert!(matches!(
            snapshot_window(-5),
            Err(WindowSnapshotError::PixelMap(_))
        ));
    }

    #[test]
    fn normalizes_bgra_and_premultiplied_alpha() {
        // BGRA pixel: B=64, G=128, R=192, A=128 (premultiplied)
        let mut buf = vec![64u8, 128, 192, 128];
        normalize_pixel_buffer(&mut buf, true, PixelMapAlphaType::Premultiplied);
        assert_eq!(buf[3], 128);
        // R (~192 * 255 / 128 -> 255), G (~128 * 255 / 128 -> 255), B (~64 * 255 / 128 -> 128)
        assert_eq!(buf[0], 255);
        assert_eq!(buf[1], 255);
        assert_eq!(buf[2], 128);
    }

    #[test]
    fn ohos_below_api15_returns_not_supported_without_ffi() {
        if version::sdk_api_version() < WINDOW_SNAPSHOT_API_LEVEL {
            assert!(matches!(
                snapshot_window(1),
                Err(WindowSnapshotError::NotSupported)
            ));
        }
    }
}
