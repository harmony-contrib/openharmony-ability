//! Clipboard capability plugin facade.
//!
//! Ports the former `crates/ability/src/clipboard/mod.rs` TSFN capability into the
//! pluginized bridge model: Rust workers call `write_image`, the async plugin marshals the
//! RGBA buffer to ArkTS through the bridge, and ArkTS writes a PixelMap to the system
//! pasteboard.

use std::{future::Future, pin::Pin};

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement, BridgePlugin,
    OpenHarmonyApp,
};

pub struct ClipboardBridgePlugin;

impl BridgePlugin for ClipboardBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.clipboard";
    const VERSION: u32 = 1;
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardImageRequest {
    /// RGBA-8888 pixel data, length must equal `width * height * 4`.
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

impl_bridge_napi_type!(ClipboardImageRequest, "ohos.clipboard.ImageRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(ClipboardAcknowledgement, "ohos.clipboard.Acknowledgement");

impl ClipboardAcknowledgement {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "Clipboard plugin rejected the requested operation",
            ))
        }
    }
}

fn validate_dimensions(rgba_len: usize, width: u32, height: u32) -> Result<()> {
    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|v| v.checked_mul(4))
        .ok_or_else(|| Error::from_reason("clipboard image dimensions overflow"))?;
    if rgba_len != expected {
        return Err(Error::from_reason(format!(
            "clipboard rgba len {rgba_len} != expected {expected} ({width}x{height}x4)"
        )));
    }
    Ok(())
}

/// Extension trait supplied by the capability package, never by `openharmony-ability` core.
pub trait ClipboardExt {
    /// Writes RGBA-8888 image data to the system clipboard.
    fn write_image(
        &self,
        rgba: Vec<u8>,
        width: u32,
        height: u32,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>>;
}

impl ClipboardExt for OpenHarmonyApp {
    fn write_image(
        &self,
        rgba: Vec<u8>,
        width: u32,
        height: u32,
    ) -> Pin<Box<dyn Future<Output = Result<()>> + Send>> {
        let validated =
            validate_dimensions(rgba.len(), width, height).map(|()| ClipboardImageRequest {
                rgba,
                width,
                height,
            });
        let bridge = self.bridge();

        Box::pin(async move {
            let response = bridge?
                .call_async::<ClipboardBridgePlugin, ClipboardImageRequest, ClipboardAcknowledgement>(
                    "write-image",
                    validated?,
                    BridgeCallOptions::default().with_timeout_ms(10_000),
                )
                .await?;
            response.ensure()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{validate_dimensions, ClipboardAcknowledgement, ClipboardImageRequest};
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn clipboard_uses_stable_named_napi_contracts() {
        assert_eq!(
            <ClipboardImageRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.clipboard.ImageRequest"
        );
        assert_eq!(
            <ClipboardAcknowledgement as BridgeNapiType>::TYPE_NAME,
            "ohos.clipboard.Acknowledgement"
        );
    }

    #[test]
    fn clipboard_validates_rgba_dimensions() {
        assert!(validate_dimensions(4 * 2 * 2, 2, 2).is_ok());
        assert!(validate_dimensions(3, 2, 2).is_err());
        assert!(validate_dimensions(0, 0, 0).is_ok());
    }
}
