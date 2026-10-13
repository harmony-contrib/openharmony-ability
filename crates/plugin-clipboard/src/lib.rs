//! Asynchronous clipboard bridge plugin facade.
//!
//! Provides `read-text`, `write-text`, and `write-image` actions through the bridge plugin model.
//! The ArkTS side uses `pasteboard.getSystemPasteboard()` to interact with the system clipboard.

use std::sync::atomic::{AtomicU64, Ordering};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
    PluginLifecycleEvent,
};

#[derive(Default)]
pub struct ClipboardBridgePlugin {
    revision: AtomicU64,
}

impl ClipboardBridgePlugin {
    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::Acquire)
    }
}

impl BridgePlugin for ClipboardBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.clipboard";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        if event.name() != "changed" {
            return Err(Error::from_reason("Unsupported clipboard event"));
        }
        let _: ClipboardChangedEvent = event.decode()?;
        self.revision.fetch_add(1, Ordering::AcqRel);
        event.respond(true)
    }

    fn on_lifecycle(&self, _event: &PluginLifecycleEvent) -> Result<()> {
        // Any new session invalidates cached clipboard data from the previous session.
        self.revision.fetch_add(1, Ordering::AcqRel);
        Ok(())
    }
}

/// One native pasteboard record. Exactly one of text, encoded_image, or uri is set.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ClipboardRecord {
    pub text: Option<String>,
    pub metadata: Option<String>,
    pub encoded_image: Option<Vec<u8>>,
    pub uri: Option<String>,
}
impl_bridge_napi_type!(ClipboardRecord, "ohos.clipboard.Record");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteRecordsRequest {
    pub records: Vec<ClipboardRecord>,
}
impl_bridge_napi_type!(
    ClipboardWriteRecordsRequest,
    "ohos.clipboard.WriteRecordsRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardReadRecordsResponse {
    pub records: Vec<ClipboardRecord>,
}
impl_bridge_napi_type!(
    ClipboardReadRecordsResponse,
    "ohos.clipboard.ReadRecordsResponse"
);

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ClipboardChangedEvent {}
impl_bridge_napi_type!(ClipboardChangedEvent, "ohos.clipboard.ChangedEvent");

fn validate_records(records: &[ClipboardRecord]) -> Result<()> {
    if records.is_empty() || records.len() > 512 {
        return Err(Error::from_reason("clipboard requires 1..512 records"));
    }
    for record in records {
        let count = usize::from(record.text.is_some())
            + usize::from(record.encoded_image.is_some())
            + usize::from(record.uri.is_some());
        if count != 1 || record.metadata.is_some() && record.text.is_none() {
            return Err(Error::from_reason(
                "clipboard record must contain one supported value; metadata requires text",
            ));
        }
        if record.encoded_image.as_ref().is_some_and(Vec::is_empty)
            || record
                .uri
                .as_ref()
                .is_some_and(|uri| !uri.starts_with("file://") || uri.contains('\0'))
        {
            return Err(Error::from_reason("invalid clipboard image or file URI"));
        }
    }
    Ok(())
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

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ClipboardReadContentResponse {
    pub text: Option<String>,
    pub png: Option<Vec<u8>>,
    pub uris: Vec<String>,
}

impl_bridge_napi_type!(
    ClipboardReadContentResponse,
    "ohos.clipboard.ReadContentResponse"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteEncodedImageRequest {
    pub bytes: Vec<u8>,
}

impl_bridge_napi_type!(
    ClipboardWriteEncodedImageRequest,
    "ohos.clipboard.WriteEncodedImageRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardWriteUrisRequest {
    pub uris: Vec<String>,
}

impl_bridge_napi_type!(ClipboardWriteUrisRequest, "ohos.clipboard.WriteUrisRequest");

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

    pub async fn read_records(&self) -> Result<Vec<ClipboardRecord>> {
        Ok(self
            .call::<ClipboardReadTextRequest, ClipboardReadRecordsResponse>(
                "read-records",
                ClipboardReadTextRequest {},
            )
            .await?
            .records)
    }

    pub async fn write_records(&self, records: Vec<ClipboardRecord>) -> Result<()> {
        validate_records(&records)?;
        let response = self
            .call::<ClipboardWriteRecordsRequest, ClipboardWriteTextResponse>(
                "write-records",
                ClipboardWriteRecordsRequest { records },
            )
            .await?;
        if !response.accepted {
            return Err(Error::from_reason("Clipboard plugin rejected records"));
        }
        Ok(())
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

    pub async fn read_content(&self) -> Result<ClipboardReadContentResponse> {
        self.call::<ClipboardReadTextRequest, ClipboardReadContentResponse>(
            "read-content",
            ClipboardReadTextRequest {},
        )
        .await
    }

    pub async fn write_encoded_image(&self, bytes: &[u8]) -> Result<()> {
        if bytes.is_empty() {
            return Err(Error::from_reason(
                "clipboard image bytes must not be empty",
            ));
        }
        let response = self
            .call::<ClipboardWriteEncodedImageRequest, ClipboardWriteImageResponse>(
                "write-encoded-image",
                ClipboardWriteEncodedImageRequest {
                    bytes: bytes.to_vec(),
                },
            )
            .await?;
        if response.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "Clipboard plugin rejected encoded image",
            ))
        }
    }

    pub async fn write_uris(&self, uris: Vec<String>) -> Result<()> {
        if uris.is_empty() || uris.iter().any(|uri| !uri.starts_with("file://")) {
            return Err(Error::from_reason(
                "clipboard URIs must be non-empty file:// URIs",
            ));
        }
        let response = self
            .call::<ClipboardWriteUrisRequest, ClipboardWriteTextResponse>(
                "write-uris",
                ClipboardWriteUrisRequest { uris },
            )
            .await?;
        if response.accepted {
            Ok(())
        } else {
            Err(Error::from_reason("Clipboard plugin rejected URIs"))
        }
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
    fn record_contract_and_validation() {
        assert_eq!(ClipboardRecord::TYPE_NAME, "ohos.clipboard.Record");
        assert_eq!(
            ClipboardWriteRecordsRequest::TYPE_NAME,
            "ohos.clipboard.WriteRecordsRequest"
        );
        assert_eq!(
            ClipboardReadRecordsResponse::TYPE_NAME,
            "ohos.clipboard.ReadRecordsResponse"
        );
        assert_eq!(
            ClipboardChangedEvent::TYPE_NAME,
            "ohos.clipboard.ChangedEvent"
        );
        let text = ClipboardRecord {
            text: Some(String::new()),
            metadata: Some("metadata".into()),
            ..Default::default()
        };
        let image = ClipboardRecord {
            encoded_image: Some(vec![1]),
            ..Default::default()
        };
        assert!(validate_records(&[text.clone(), image.clone()]).is_ok());
        assert!(validate_records(&[]).is_err());
        assert!(validate_records(&[ClipboardRecord::default()]).is_err());
        assert!(validate_records(&[ClipboardRecord {
            uri: Some("file:///a".into()),
            ..text
        }])
        .is_err());
        assert!(validate_records(&[ClipboardRecord {
            encoded_image: Some(vec![]),
            ..image
        }])
        .is_err());
    }

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
