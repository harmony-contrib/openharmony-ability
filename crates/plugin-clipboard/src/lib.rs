//! Asynchronous clipboard bridge plugin facade.
//!
//! Provides `read-text`, `write-text`, and `write-image` actions through the bridge plugin model.
//! The ArkTS side uses `pasteboard.getSystemPasteboard()` to interact with the system clipboard.

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

pub struct ClipboardBridgePlugin;

impl BridgePlugin for ClipboardBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.clipboard";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

// ── read-text ───────────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ClipboardReadTextRequest {}

impl_bridge_napi_type!(ClipboardReadTextRequest, "ohos.clipboard.ReadTextRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardReadTextResponse {
    pub text: Option<String>,
}

impl_bridge_napi_type!(ClipboardReadTextResponse, "ohos.clipboard.ReadTextResponse");

// ── write-text ──────────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteTextRequest {
    pub text: String,
}

impl_bridge_napi_type!(ClipboardWriteTextRequest, "ohos.clipboard.WriteTextRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteTextResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    ClipboardWriteTextResponse,
    "ohos.clipboard.WriteTextResponse"
);

// ── write-image ─────────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteImageRequest {
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

impl_bridge_napi_type!(
    ClipboardWriteImageRequest,
    "ohos.clipboard.WriteImageRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteImageResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    ClipboardWriteImageResponse,
    "ohos.clipboard.WriteImageResponse"
);

// ── write-html ───────────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteHtmlRequest {
    pub html: String,
}

impl_bridge_napi_type!(ClipboardWriteHtmlRequest, "ohos.clipboard.WriteHtmlRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteHtmlResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    ClipboardWriteHtmlResponse,
    "ohos.clipboard.WriteHtmlResponse"
);

// ── clear ────────────────────────────────────────────────────────────────────────

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ClipboardClearRequest {}

impl_bridge_napi_type!(ClipboardClearRequest, "ohos.clipboard.ClearRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardClearResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(ClipboardClearResponse, "ohos.clipboard.ClearResponse");

/// Worker-safe facade for the system clipboard.
#[derive(Clone)]
pub struct ClipboardClient {
    bridge: BridgeRuntime,
}

impl ClipboardClient {
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

pub trait ClipboardExt {
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
}
