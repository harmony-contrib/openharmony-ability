//! Screenshot facade for openharmony-ability webviews.
//!
//! Routes `capture-webview` / `pick-color` actions through the `ohos.webview` bridge
//! plugin (the ArkTS side captures the live PixelMap via ArkWeb `webPageSnapshot`,
//! packs it as a base64 PNG or reads a single BGRA pixel, and releases the PixelMap
//! in the same action). This crate adds no ArkTS plugin of its own — the Rust-side
//! registration of `WebviewBridgePlugin` already lives in tauri-runtime-wry.
//!
//! OHOS-only by construction: everything below depends on
//! `openharmony-ability-plugin-webview`, which never participates in Windows/macOS/Linux
//! builds.

use napi_ohos::{Error, Result};
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_webview::{WebviewCaptureResponse, WebviewClient, WebviewPickColorResponse};

/// A viewport webview screenshot (the on-screen area, not the full scrollable page):
/// a base64-encoded PNG plus its pixel dimensions.
///
/// base64 (not raw bytes) — a `Vec<u8>` in a napi object would serialize as
/// `Array<number>`, inflating a multi-hundred-KB PNG ~8x in memory.
#[derive(Clone, Debug)]
pub struct CapturedImage {
    /// Base64-encoded PNG image data.
    pub png_base64: String,
    /// Snapshot width in pixels.
    pub width: u32,
    /// Snapshot height in pixels.
    pub height: u32,
}

impl From<WebviewCaptureResponse> for CapturedImage {
    fn from(response: WebviewCaptureResponse) -> Self {
        Self {
            png_base64: response.png_base64,
            width: response.width,
            height: response.height,
        }
    }
}

/// A single pixel's color channels (0-255 each).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgba {
    pub r: u32,
    pub g: u32,
    pub b: u32,
    pub a: u32,
}

impl From<WebviewPickColorResponse> for Rgba {
    fn from(response: WebviewPickColorResponse) -> Self {
        Self {
            r: response.r,
            g: response.g,
            b: response.b,
            a: response.a,
        }
    }
}

/// Typed error surface for webview screenshot operations.
///
/// Mapped from the bridge error reason by message marker (design D5):
/// `"Unknown WebView controller"` → [`ScreenshotError::UnknownWebview`],
/// `webPageSnapshot` / `timed out` markers → [`ScreenshotError::SnapshotUnavailable`],
/// everything else → [`ScreenshotError::Internal`].
#[derive(Clone, Debug)]
pub enum ScreenshotError {
    /// No WebView is registered under the requested id.
    UnknownWebview { message: String },
    /// The snapshot could not be produced (retries exhausted, timeout, or the webview
    /// has not rendered its first frame yet).
    SnapshotUnavailable { message: String },
    /// Any other failure (PNG packing, pixel read, coordinate bounds, ...).
    Internal { message: String },
}

impl ScreenshotError {
    fn from_reason(reason: &str) -> Self {
        let lower = reason.to_ascii_lowercase();
        if reason.contains("Unknown WebView controller") {
            Self::UnknownWebview {
                message: reason.to_string(),
            }
        } else if lower.contains("webpagesnapshot") || lower.contains("timed out") {
            Self::SnapshotUnavailable {
                message: reason.to_string(),
            }
        } else {
            Self::Internal {
                message: reason.to_string(),
            }
        }
    }
}

impl std::fmt::Display for ScreenshotError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnknownWebview { message } => write!(f, "unknown webview: {message}"),
            Self::SnapshotUnavailable { message } => {
                write!(f, "webview snapshot unavailable: {message}")
            }
            Self::Internal { message } => write!(f, "screenshot internal error: {message}"),
        }
    }
}

impl std::error::Error for ScreenshotError {}

impl From<ScreenshotError> for Error {
    fn from(err: ScreenshotError) -> Self {
        Error::from_reason(err.to_string())
    }
}

/// Worker-safe facade for webview screenshots.
///
/// Construct via [`ScreenshotExt::screenshot`] on an [`OpenHarmonyApp`]. All methods are
/// async — never block on them from the main thread.
#[derive(Clone)]
pub struct ScreenshotClient {
    webviews: WebviewClient,
}

impl ScreenshotClient {
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            webviews: WebviewClient::new(app)?,
        })
    }

    /// Captures the WebView registered under `id` as a base64 PNG with its dimensions.
    pub async fn capture_webview(
        &self,
        id: impl AsRef<str>,
    ) -> std::result::Result<CapturedImage, ScreenshotError> {
        self.webviews
            .handle(id.as_ref().to_string())
            .capture_webview()
            .await
            .map(CapturedImage::from)
            .map_err(|e| ScreenshotError::from_reason(&e.reason))
    }

    /// Reads the color of the pixel at snapshot coordinates (`x`, `y`) from the WebView
    /// registered under `id`.
    ///
    /// Coordinates use the snapshot's pixel coordinate system (the same one as the
    /// dimensions returned by [`ScreenshotClient::capture_webview`]). Out-of-bounds
    /// coordinates reject with [`ScreenshotError::Internal`].
    pub async fn pick_color(
        &self,
        id: impl AsRef<str>,
        x: u32,
        y: u32,
    ) -> std::result::Result<Rgba, ScreenshotError> {
        self.webviews
            .handle(id.as_ref().to_string())
            .pick_color(x, y)
            .await
            .map(Rgba::from)
            .map_err(|e| ScreenshotError::from_reason(&e.reason))
    }
}

/// Extension trait for constructing a [`ScreenshotClient`].
pub trait ScreenshotExt {
    /// Returns a webview screenshot facade bound to this app's bridge runtime.
    fn screenshot(&self) -> Result<ScreenshotClient>;
}

impl ScreenshotExt for OpenHarmonyApp {
    fn screenshot(&self) -> Result<ScreenshotClient> {
        ScreenshotClient::new(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_controller_marker_maps_to_unknown_webview() {
        let err = ScreenshotError::from_reason("Unknown WebView controller 'main'");
        assert!(matches!(err, ScreenshotError::UnknownWebview { .. }));
    }

    #[test]
    fn snapshot_failure_markers_map_to_snapshot_unavailable() {
        for reason in [
            "webPageSnapshot failed: 17100001 - internal error",
            "webPageSnapshot timed out after 10s",
            "webPageSnapshot returned empty or failed result",
            "capture failed: timed out",
        ] {
            let err = ScreenshotError::from_reason(reason);
            assert!(
                matches!(err, ScreenshotError::SnapshotUnavailable { .. }),
                "expected SnapshotUnavailable for {reason}"
            );
        }
    }

    #[test]
    fn other_reasons_map_to_internal() {
        for reason in [
            "capture-webview failed: ImagePacker error 62980115",
            "pick-color failed: pick-color coordinates (5, 5) out of captured bounds 100x50",
            "pick-color requires x and y as integers",
        ] {
            let err = ScreenshotError::from_reason(reason);
            assert!(
                matches!(err, ScreenshotError::Internal { .. }),
                "expected Internal for {reason}"
            );
        }
    }

    #[test]
    fn captured_image_and_rgba_convert_from_wire_types() {
        let image = CapturedImage::from(WebviewCaptureResponse {
            png_base64: "iVBORw0KGgo=".to_string(),
            width: 800,
            height: 600,
        });
        assert_eq!(image.width, 800);
        assert_eq!(image.height, 600);
        assert_eq!(image.png_base64, "iVBORw0KGgo=");

        let color = Rgba::from(WebviewPickColorResponse {
            r: 255,
            g: 0,
            b: 0,
            a: 255,
        });
        assert_eq!(
            color,
            Rgba {
                r: 255,
                g: 0,
                b: 0,
                a: 255
            }
        );
    }
}
