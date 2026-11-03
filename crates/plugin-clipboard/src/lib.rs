//! Asynchronous clipboard bridge plugin facade.
//!
//! Provides `read-text`, `write-text`, `write-image`, `read-image`, and
//! `write-html` actions through the bridge plugin model. The ArkTS side uses
//! `pasteboard.getSystemPasteboard()` to interact with the system clipboard.

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

/// Bridge plugin exposing the `ohos.clipboard` actions.
pub struct ClipboardBridgePlugin;

impl BridgePlugin for ClipboardBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.clipboard";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

// ── read-text ───────────────────────────────────────────────────────────────────

/// `read-text` request payload (empty).
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ClipboardReadTextRequest {}

impl_bridge_napi_type!(ClipboardReadTextRequest, "ohos.clipboard.ReadTextRequest");

/// `read-text` response payload.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardReadTextResponse {
    /// Clipboard text content, or `None` when the clipboard holds no text.
    pub text: Option<String>,
}

impl_bridge_napi_type!(ClipboardReadTextResponse, "ohos.clipboard.ReadTextResponse");

// ── write-text ──────────────────────────────────────────────────────────────────

/// `write-text` request payload.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteTextRequest {
    /// Text to place on the clipboard (replaces all existing content).
    pub text: String,
}

impl_bridge_napi_type!(ClipboardWriteTextRequest, "ohos.clipboard.WriteTextRequest");

/// `write-text` response payload.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteTextResponse {
    /// `true` when the ArkTS side accepted the write.
    pub accepted: bool,
}

impl_bridge_napi_type!(
    ClipboardWriteTextResponse,
    "ohos.clipboard.WriteTextResponse"
);

// ── write-image ─────────────────────────────────────────────────────────────────

/// `write-image` request payload.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteImageRequest {
    /// RGBA8 pixel data, row-major top-to-bottom (`width * height * 4` bytes).
    pub rgba: Vec<u8>,
    /// Image width in pixels.
    pub width: u32,
    /// Image height in pixels.
    pub height: u32,
}

impl_bridge_napi_type!(
    ClipboardWriteImageRequest,
    "ohos.clipboard.WriteImageRequest"
);

/// `write-image` response payload.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteImageResponse {
    /// `true` when the ArkTS side accepted the write.
    pub accepted: bool,
}

impl_bridge_napi_type!(
    ClipboardWriteImageResponse,
    "ohos.clipboard.WriteImageResponse"
);

// ── read-image ───────────────────────────────────────────────────────────────────

/// `read-image` request payload (empty).
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ClipboardReadImageRequest {}

impl_bridge_napi_type!(ClipboardReadImageRequest, "ohos.clipboard.ReadImageRequest");

/// The ArkTS side packs the clipboard PixelMap as a base64 PNG - a `Vec<u8>`
/// napi object would cross the bridge as `Array<number>`, inflating a
/// multi-hundred-KB PNG ~8x in memory (same contract as plugin-webview's
/// capture response).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardReadImageResponse {
    /// Base64-encoded PNG of the clipboard image.
    pub png_base64: String,
    /// Image width in pixels.
    pub width: u32,
    /// Image height in pixels.
    pub height: u32,
}

impl_bridge_napi_type!(
    ClipboardReadImageResponse,
    "ohos.clipboard.ReadImageResponse"
);

/// A clipboard image decoded to RGBA8 (row-major, top to bottom).
#[derive(Clone, Debug)]
pub struct ClipboardImage {
    /// RGBA8 pixel buffer (`width * height * 4` bytes).
    pub rgba: Vec<u8>,
    /// Image width in pixels.
    pub width: u32,
    /// Image height in pixels.
    pub height: u32,
}

// ── write-html ───────────────────────────────────────────────────────────────────

/// `write-html` request payload.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteHtmlRequest {
    /// HTML markup to place on the clipboard.
    pub html: String,
}

impl_bridge_napi_type!(ClipboardWriteHtmlRequest, "ohos.clipboard.WriteHtmlRequest");

/// `write-html` response payload.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteHtmlResponse {
    /// `true` when the ArkTS side accepted the write.
    pub accepted: bool,
}

impl_bridge_napi_type!(
    ClipboardWriteHtmlResponse,
    "ohos.clipboard.WriteHtmlResponse"
);

// ── clear ────────────────────────────────────────────────────────────────────────

/// `clear` request payload (empty).
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ClipboardClearRequest {}

impl_bridge_napi_type!(ClipboardClearRequest, "ohos.clipboard.ClearRequest");

/// `clear` response payload.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardClearResponse {
    /// `true` when the ArkTS side accepted the clear.
    pub accepted: bool,
}

impl_bridge_napi_type!(ClipboardClearResponse, "ohos.clipboard.ClearResponse");

/// Worker-safe facade for the system clipboard.
#[derive(Clone)]
pub struct ClipboardClient {
    bridge: BridgeRuntime,
}

impl ClipboardClient {
    /// Creates a client bound to the app's bridge runtime.
    ///
    /// # Errors
    /// Returns an error when the app has no bridge runtime installed yet.
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
            .call_async::<ClipboardBridgePlugin, Request, Response>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await
    }

    /// Reads the current text content from the system clipboard.
    /// Returns `None` if the clipboard contains no text.
    pub async fn read_text(&self) -> Result<Option<String>> {
        let response = self
            .call::<ClipboardReadTextRequest, ClipboardReadTextResponse>(
                "read-text",
                ClipboardReadTextRequest {},
            )
            .await?;
        Ok(response.text)
    }

    /// Writes text to the system clipboard.
    pub async fn write_text(&self, text: impl Into<String>) -> Result<()> {
        let response = self
            .call::<ClipboardWriteTextRequest, ClipboardWriteTextResponse>(
                "write-text",
                ClipboardWriteTextRequest { text: text.into() },
            )
            .await?;
        if response.accepted {
            Ok(())
        } else {
            Err(Error::from_reason("Clipboard plugin rejected write-text"))
        }
    }

    /// Writes RGBA image data to the system clipboard.
    /// The `rgba` buffer must have exactly `width * height * 4` bytes.
    pub async fn write_image(&self, rgba: &[u8], width: u32, height: u32) -> Result<()> {
        validate_image_dimensions(rgba, width, height)?;
        let response = self
            .call::<ClipboardWriteImageRequest, ClipboardWriteImageResponse>(
                "write-image",
                ClipboardWriteImageRequest {
                    rgba: rgba.to_vec(),
                    width,
                    height,
                },
            )
            .await?;
        if response.accepted {
            Ok(())
        } else {
            Err(Error::from_reason("Clipboard plugin rejected write-image"))
        }
    }

    /// Reads the current image from the system clipboard, decoded to RGBA.
    ///
    /// Errors when the clipboard holds no image or the PNG round-trip fails.
    /// A permission-gated read (READ_PASTEBOARD denied) observes an empty
    /// pasteboard and surfaces as the no-image error - same degradation as
    /// `read_text` returning `None`.
    pub async fn read_image(&self) -> Result<ClipboardImage> {
        let response = self
            .call::<ClipboardReadImageRequest, ClipboardReadImageResponse>(
                "read-image",
                ClipboardReadImageRequest {},
            )
            .await?;
        decode_png_base64(&response.png_base64, response.width, response.height)
    }

    /// Writes HTML content to the system clipboard.
    pub async fn write_html(&self, html: impl Into<String>) -> Result<()> {
        let response = self
            .call::<ClipboardWriteHtmlRequest, ClipboardWriteHtmlResponse>(
                "write-html",
                ClipboardWriteHtmlRequest { html: html.into() },
            )
            .await?;
        if response.accepted {
            Ok(())
        } else {
            Err(Error::from_reason("Clipboard plugin rejected write-html"))
        }
    }

    /// Clears all content from the system clipboard.
    pub async fn clear(&self) -> Result<()> {
        let response = self
            .call::<ClipboardClearRequest, ClipboardClearResponse>(
                "clear",
                ClipboardClearRequest {},
            )
            .await?;
        if response.accepted {
            Ok(())
        } else {
            Err(Error::from_reason("Clipboard plugin rejected clear"))
        }
    }
}

/// Extension trait providing the `clipboard()` client on `OpenHarmonyApp`.
pub trait ClipboardExt {
    /// Returns a worker-safe [`ClipboardClient`] for this app.
    ///
    /// # Errors
    /// Returns an error when the app has no bridge runtime installed yet.
    fn clipboard(&self) -> Result<ClipboardClient>;
}

impl ClipboardExt for OpenHarmonyApp {
    fn clipboard(&self) -> Result<ClipboardClient> {
        ClipboardClient::new(self)
    }
}

/// Validates that `rgba.len() == width * height * 4` without overflow.
fn validate_image_dimensions(rgba: &[u8], width: u32, height: u32) -> Result<()> {
    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|v| v.checked_mul(4))
        .ok_or_else(|| Error::from_reason("clipboard image dimensions overflow"))?;
    if rgba.len() != expected {
        return Err(Error::from_reason(format!(
            "clipboard rgba len {} != expected {} ({}x{}x4)",
            rgba.len(),
            expected,
            width,
            height
        )));
    }
    Ok(())
}

/// Upper bound on the total pixel count `decode_png_base64` will decode.
///
/// The output buffer is sized straight from the PNG header
/// (`reader.output_buffer_size()`), so a lying IHDR can request an arbitrary
/// allocation before any pixel data is validated - a ~45-byte CRC-valid
/// file claiming 65535x65535 RGBA asks for a ~16 GiB zeroed buffer. Capping
/// at 1<<26 px bounds that allocation to 256 MiB (RGBA8) while leaving
/// headroom for every realistic clipboard image: the pasteboard itself is
/// capped at 128 MB by default (≈33 Mpx RGBA), a 4K screenshot is 8.3 Mpx,
/// and an extreme 1080x50000 long screenshot is 54 Mpx.
/// Mirrored by MAX_DECODE_PIXELS in ClipboardPlugin.ets.
/// (Eulogizethesun/tauri#142)
const MAX_DECODE_PIXELS: u64 = 1 << 26;

/// Decodes the bridge's base64 PNG response into RGBA8.
///
/// `width`/`height` come from the ArkTS PixelMap info and are cross-checked
/// against the decoded PNG (the PNG is the source of truth for the payload;
/// a mismatch means the packer produced different dimensions than it
/// reported - treated as corruption).
fn decode_png_base64(png_base64: &str, width: u32, height: u32) -> Result<ClipboardImage> {
    use base64::Engine as _;

    let reason = |msg: String| Error::from_reason(format!("clipboard read-image: {msg}"));

    let bytes = base64::engine::general_purpose::STANDARD
        .decode(png_base64)
        .map_err(|e| reason(format!("base64 decode failed: {e}")))?;
    let mut decoder = png::Decoder::new(std::io::Cursor::new(&bytes));
    // Palette → RGB, <8-bit grayscale → 8-bit, tRNS → alpha, 16-bit → 8-bit,
    // so only the four 8-bit types remain below.
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder
        .read_info()
        .map_err(|e| reason(format!("PNG decode failed: {e}")))?;
    // The IHDR is untrusted until the pixel data decodes - enforce the size
    // cap before it drives the output-buffer allocation.
    let (header_w, header_h) = (reader.info().width, reader.info().height);
    let pixels = header_w as u64 * header_h as u64;
    if pixels > MAX_DECODE_PIXELS {
        return Err(reason(format!(
            "image too large: {header_w}x{header_h} ({pixels} px) exceeds the {MAX_DECODE_PIXELS} px limit"
        )));
    }
    let mut buf = vec![0u8; reader.output_buffer_size()];
    let info = reader
        .next_frame(&mut buf)
        .map_err(|e| reason(format!("PNG decode failed: {e}")))?;
    let (w, h) = (info.width, info.height);
    if (w, h) != (width, height) {
        return Err(reason(format!(
            "dimension mismatch: bridge reported {width}x{height}, PNG is {w}x{h}"
        )));
    }
    let rgba = match info.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => {
            let mut out = Vec::with_capacity(buf.len() / 3 * 4);
            for px in buf.chunks_exact(3) {
                out.extend_from_slice(&[px[0], px[1], px[2], 255]);
            }
            out
        }
        png::ColorType::GrayscaleAlpha => {
            let mut out = Vec::with_capacity(buf.len() / 2 * 4);
            for px in buf.chunks_exact(2) {
                out.extend_from_slice(&[px[0], px[0], px[0], px[1]]);
            }
            out
        }
        png::ColorType::Grayscale => {
            let mut out = Vec::with_capacity(buf.len() * 4);
            for px in buf.chunks_exact(1) {
                out.extend_from_slice(&[px[0], px[0], px[0], 255]);
            }
            out
        }
        // Unreachable with normalize_to_color8 (EXPAND maps Indexed → Rgb in
        // the output color type) - kept as a defensive arm.
        png::ColorType::Indexed => {
            return Err(reason(
                "unexpected indexed output after normalize_to_color8".into(),
            ))
        }
    };
    Ok(ClipboardImage {
        rgba,
        width: w,
        height: h,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clipboard_plugin_targets_ability_context() {
        assert_eq!(ClipboardBridgePlugin::ID, "ohos.clipboard");
        assert_eq!(
            ClipboardBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }

    #[test]
    fn clipboard_types_have_stable_named_napi_contracts() {
        assert_eq!(
            <ClipboardReadTextRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.clipboard.ReadTextRequest"
        );
        assert_eq!(
            <ClipboardReadTextResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.clipboard.ReadTextResponse"
        );
        assert_eq!(
            <ClipboardWriteTextRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.clipboard.WriteTextRequest"
        );
        assert_eq!(
            <ClipboardWriteTextResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.clipboard.WriteTextResponse"
        );
        assert_eq!(
            <ClipboardWriteImageRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.clipboard.WriteImageRequest"
        );
        assert_eq!(
            <ClipboardWriteImageResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.clipboard.WriteImageResponse"
        );
        assert_eq!(
            <ClipboardReadImageRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.clipboard.ReadImageRequest"
        );
        assert_eq!(
            <ClipboardReadImageResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.clipboard.ReadImageResponse"
        );
    }

    #[test]
    fn image_dimension_validation_rejects_mismatched_lengths() {
        assert!(validate_image_dimensions(&[0; 16], 2, 2).is_ok());
        assert!(validate_image_dimensions(&[0; 15], 2, 2).is_err());
        assert!(validate_image_dimensions(&[], 0, 0).is_ok());
        assert!(validate_image_dimensions(&[0; 4], 1, 1).is_ok());
    }

    #[test]
    fn image_dimension_validation_rejects_overflow() {
        assert!(validate_image_dimensions(&[], u32::MAX, u32::MAX).is_err());
    }

    /// Encodes a w×h RGBA image to a base64 PNG (the same wire shape the
    /// ArkTS ImagePacker produces) for the decode tests.
    fn encode_png_base64(width: u32, height: u32, rgba: &[u8]) -> String {
        use base64::Engine as _;

        let mut bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut bytes, width, height);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder.write_header().expect("png header");
            writer.write_image_data(rgba).expect("png image data");
        }
        base64::engine::general_purpose::STANDARD.encode(&bytes)
    }

    #[test]
    fn read_image_decodes_base64_png_to_rgba() {
        // 2×1 RGBA: red, transparent
        let rgba = [255, 0, 0, 255, 255, 0, 0, 0];
        let png_base64 = encode_png_base64(2, 1, &rgba);
        let image = decode_png_base64(&png_base64, 2, 1).expect("decode ok");
        assert_eq!(image.width, 2);
        assert_eq!(image.height, 1);
        assert_eq!(image.rgba, rgba);
    }

    #[test]
    fn read_image_rejects_dimension_mismatch() {
        let png_base64 = encode_png_base64(2, 1, &[255, 0, 0, 255, 255, 0, 0, 0]);
        let err = decode_png_base64(&png_base64, 3, 1).expect_err("mismatch rejected");
        assert!(err.reason.contains("dimension mismatch"));
    }

    #[test]
    fn read_image_rejects_invalid_base64() {
        let err = decode_png_base64("!!not base64!!", 1, 1).expect_err("bad base64 rejected");
        assert!(err.reason.contains("base64 decode failed"));
    }

    /// Minimal CRC-32 (IEEE 802.3, as the PNG spec requires) for the
    /// hand-built PNG headers below - the png crate checks chunk CRCs during
    /// `read_info`, so the forged IHDR/IDAT must be self-consistent.
    fn crc32(bytes: &[u8]) -> u32 {
        let mut crc = !0u32;
        for &byte in bytes {
            crc ^= byte as u32;
            for _ in 0_i32..8_i32 {
                crc = if crc & 1 != 0 {
                    (crc >> 1_i32) ^ 0xEDB8_8320
                } else {
                    crc >> 1_i32
                };
            }
        }
        !crc
    }

    fn push_png_chunk(out: &mut Vec<u8>, chunk_type: &[u8; 4], data: &[u8]) {
        let mut crc_input = Vec::new();
        crc_input.extend_from_slice(chunk_type);
        crc_input.extend_from_slice(data);
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        out.extend_from_slice(chunk_type);
        out.extend_from_slice(data);
        out.extend_from_slice(&crc32(&crc_input).to_be_bytes());
    }

    /// Builds a base64 PNG whose IHDR claims `width`x`height` 8-bit RGBA but
    /// carries no pixel data (empty IDAT). `read_info` succeeds on this - it
    /// only needs to reach the first IDAT chunk - so the decode path runs
    /// the pre-allocation pixel check against a lying header.
    fn lying_header_png_base64(width: u32, height: u32) -> String {
        use base64::Engine as _;

        let mut png = Vec::new();
        png.extend_from_slice(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        let mut ihdr = Vec::new();
        ihdr.extend_from_slice(&width.to_be_bytes());
        ihdr.extend_from_slice(&height.to_be_bytes());
        // 8-bit RGBA, deflate, adaptive filtering, no interlace.
        ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
        push_png_chunk(&mut png, b"IHDR", &ihdr);
        push_png_chunk(&mut png, b"IDAT", &[]);
        base64::engine::general_purpose::STANDARD.encode(&png)
    }

    #[test]
    fn read_image_rejects_oversized_png_header_before_allocating() {
        // 65535x65535 RGBA would demand a ~16 GiB output buffer from a
        // ~45-byte file; the cap must fire before that allocation.
        let png_base64 = lying_header_png_base64(65535, 65535);
        let err =
            decode_png_base64(&png_base64, 65535, 65535).expect_err("oversized IHDR rejected");
        assert!(err.reason.contains("image too large"));
    }

    #[test]
    fn read_image_pixel_cap_boundary() {
        // One row over the cap (8192x8193) is rejected...
        let over = lying_header_png_base64(8192, 8193);
        assert!(decode_png_base64(&over, 8192, 8193)
            .expect_err("one row over the cap is rejected")
            .reason
            .contains("image too large"));
        // ...while a small lying header passes the cap and only fails later
        // at decode (empty IDAT) - proving the check gates the allocation,
        // not decoding itself.
        let small = lying_header_png_base64(2, 1);
        let err = decode_png_base64(&small, 2, 1).expect_err("empty IDAT fails decode");
        assert!(err.reason.contains("PNG decode failed"));
    }
}
