//! Native-only clipboard facade. The paired HAR supplies registration identity,
//! not a second data transport. Async methods execute synchronous native calls
//! when polled; callers choose their worker/executor. No thread is spawned here.

mod mime;

pub use mime::{ClipboardError, Result};

impl From<ClipboardError> for napi_ohos::Error {
    fn from(error: ClipboardError) -> Self {
        Self::from_reason(error.to_string())
    }
}

use mime::{Entry, NativeEntry};
use napi_derive_ohos::napi;
use ohos_pasteboard_binding::Pasteboard;
use ohos_udmf_binding::{UdmfData, UdmfRecord, UdsHtml, UdsPlainText};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeContextRequirement, BridgePlugin, OpenHarmonyApp,
};

#[derive(Default)]
pub struct ClipboardBridgePlugin;

impl ClipboardBridgePlugin {
    /// Pulls the native counter, not a subscription. Requires the `api-18`
    /// feature and runtime API 18. Zero is an explicit error; service restarts
    /// reset the counter. Do not treat it as a globally monotonic sequence.
    pub fn revision(&self) -> Result<u32> {
        #[cfg(feature = "api-18")]
        {
            require_api(18)?;
            mime::revision(Pasteboard::new().change_count())
        }
        #[cfg(not(feature = "api-18"))]
        Err(ClipboardError::ApiUnavailable { required: 18 })
    }
}

impl BridgePlugin for ClipboardBridgePlugin {
    type Mode = AsyncBridge;
    const ID: &'static str = "ohos.clipboard";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

/// A convenience projection of one record. Use `read_mime` for all representations.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct ClipboardRecord {
    pub text: Option<String>,
    pub metadata: Option<String>,
    pub encoded_image: Option<Vec<u8>>,
    pub uri: Option<String>,
}
impl_bridge_napi_type!(ClipboardRecord, "ohos.clipboard.Record");

/// One exact representation. Text/HTML must be UTF-8 without embedded NUL;
/// other formats are opaque bytes and cannot be empty on the native API.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardMimeContent {
    pub mime: String,
    pub data: Vec<u8>,
}
impl_bridge_napi_type!(ClipboardMimeContent, "ohos.clipboard.MimeContent");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ClipboardReadMimeResponse {
    pub contents: Vec<ClipboardMimeContent>,
    pub available: Vec<String>,
}
impl_bridge_napi_type!(ClipboardReadMimeResponse, "ohos.clipboard.ReadMimeResponse");

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

/// Worker-safe configuration only. Native owners are scoped to each operation;
/// no `Env`, platform object, bridge runtime, or native handle is retained.
#[derive(Clone, Default)]
pub struct ClipboardClient {
    metadata_mime_type: Option<String>,
}

impl ClipboardClient {
    pub fn new(_app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self::default())
    }

    /// Configures application-owned text metadata. No legacy/default MIME is
    /// inferred. Writers and readers must configure the same custom MIME.
    pub fn with_metadata_mime_type(mut self, mime: impl Into<String>) -> Result<Self> {
        let mime = mime.into().to_ascii_lowercase();
        mime::validate_mimes(std::iter::once(mime.as_str()))?;
        let token = |part: &str| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"!#$&^_.+-".contains(&byte))
        };
        if !mime
            .split_once('/')
            .is_some_and(|(kind, subtype)| token(kind) && token(subtype))
            || mime::native_type(&mime) != mime
            || mime.starts_with("general.")
            || mime.starts_with("openharmony.")
        {
            return Err(invalid("metadata MIME must be a custom type/subtype"));
        }
        self.metadata_mime_type = Some(mime);
        Ok(self)
    }

    pub async fn read_mime(
        &self,
        mimes: Vec<String>,
        list: bool,
    ) -> Result<ClipboardReadMimeResponse> {
        mime::validate_mimes(mimes.iter().map(String::as_str))?;
        let board = native_board()?;
        if !board.has_data() {
            return Ok(ClipboardReadMimeResponse {
                contents: Vec::new(),
                available: Vec::new(),
            });
        }
        // Metadata-only requests need not read clipboard contents on API 14+.
        #[cfg(feature = "api-14")]
        if mimes.is_empty() && list {
            require_api(14)?;
            return Ok(ClipboardReadMimeResponse {
                contents: Vec::new(),
                available: mime::available(
                    board
                        .mime_types()
                        .map_err(native_error)?
                        .iter()
                        .map(String::as_str),
                ),
            });
        }
        if mimes.is_empty() && !list {
            return Ok(ClipboardReadMimeResponse {
                contents: Vec::new(),
                available: Vec::new(),
            });
        }
        let snapshot = read_native(&board, Some(&mimes), list)?;
        Ok(ClipboardReadMimeResponse {
            contents: mime::select(&snapshot.records, &mimes)
                .into_iter()
                .map(|entry| ClipboardMimeContent {
                    mime: entry.format,
                    data: entry.bytes,
                })
                .collect(),
            available: snapshot.available,
        })
    }

    /// Writes multiple representations of a single record. An empty vector
    /// clears the board; an empty opaque representation is a typed error.
    pub async fn write_mime(&self, contents: Vec<ClipboardMimeContent>) -> Result<()> {
        let entries = contents
            .into_iter()
            .map(|content| Entry {
                format: content.mime,
                bytes: content.data,
            })
            .collect();
        let encoded = mime::encode(entries)?;
        if encoded.is_empty() {
            return self.clear().await;
        }
        write_native(vec![encoded])
    }

    pub async fn read_records(&self) -> Result<Vec<ClipboardRecord>> {
        let board = native_board()?;
        if !board.has_data() {
            return Ok(Vec::new());
        }
        read_native(&board, None, false)?
            .records
            .into_iter()
            .filter_map(|entries| self.project_record(entries).transpose())
            .collect()
    }

    /// No hidden platform authorization path exists. Applications must arrange
    /// permission/temporary paste access themselves, then call `read_records`.
    pub async fn read_authorized_records(&self) -> Result<Vec<ClipboardRecord>> {
        Err(ClipboardError::AuthorizationRequired)
    }

    pub async fn write_records(&self, records: Vec<ClipboardRecord>) -> Result<()> {
        if records.is_empty() || records.len() > mime::MAX_REPRESENTATIONS {
            return Err(invalid("clipboard requires 1..512 records"));
        }
        let mut native = Vec::with_capacity(records.len());
        for record in records {
            let count = usize::from(record.text.is_some())
                + usize::from(record.encoded_image.is_some())
                + usize::from(record.uri.is_some());
            if count != 1 || record.metadata.is_some() && record.text.is_none() {
                return Err(invalid(
                    "each clipboard record requires one value; metadata requires text",
                ));
            }
            let mut entries = Vec::new();
            if let Some(text) = record.text {
                entries.push(Entry {
                    format: "text/plain".into(),
                    bytes: text.into_bytes(),
                });
                if let Some(metadata) = record.metadata {
                    let mime = self.metadata_mime_type.as_ref().ok_or_else(|| {
                        invalid("configure with_metadata_mime_type before writing metadata")
                    })?;
                    entries.push(Entry {
                        format: mime.clone(),
                        bytes: metadata.into_bytes(),
                    });
                }
            } else if let Some(image) = record.encoded_image {
                entries.push(Entry {
                    format: mime::image_mime(&image)?.into(),
                    bytes: image,
                });
            } else if let Some(uri) = record.uri {
                validate_uri(&uri)?;
                entries.push(Entry {
                    format: "text/uri-list".into(),
                    bytes: uri.into_bytes(),
                });
            }
            native.push(mime::encode(entries)?);
        }
        write_native(native)
    }

    pub async fn read_text(&self) -> Result<Option<String>> {
        let response = self.read_mime(vec!["text/plain".into()], false).await?;
        response
            .contents
            .into_iter()
            .next()
            .map(|content| utf8(content.data, "text/plain"))
            .transpose()
    }

    pub async fn read_content(&self) -> Result<ClipboardReadContentResponse> {
        let mut content = ClipboardReadContentResponse::default();
        let board = native_board()?;
        if !board.has_data() {
            return Ok(content);
        }
        for entry in read_native(&board, None, false)?
            .records
            .into_iter()
            .flatten()
        {
            match entry.format.as_str() {
                "text/plain" if content.text.is_none() => {
                    content.text = Some(utf8(entry.bytes, "text/plain")?);
                }
                "image/png" if content.png.is_none() => {
                    content.png = Some(entry.bytes);
                }
                "text/uri-list" => {
                    let uri = utf8(entry.bytes, "text/uri-list")?;
                    validate_uri(&uri)?;
                    content.uris.push(uri);
                }
                _ => {}
            }
        }
        Ok(content)
    }

    pub async fn write_text(&self, text: impl Into<String>) -> Result<()> {
        self.write_mime(vec![ClipboardMimeContent {
            mime: "text/plain".into(),
            data: text.into().into_bytes(),
        }])
        .await
    }

    pub async fn write_html(&self, html: impl Into<String>) -> Result<()> {
        self.write_mime(vec![ClipboardMimeContent {
            mime: "text/html".into(),
            data: html.into().into_bytes(),
        }])
        .await
    }

    /// Identifies common encoded formats without decoding/reencoding their bytes.
    pub async fn write_encoded_image(&self, bytes: &[u8]) -> Result<()> {
        self.write_mime(vec![ClipboardMimeContent {
            mime: mime::image_mime(bytes)?.into(),
            data: bytes.to_vec(),
        }])
        .await
    }

    /// Explicit RGBA convenience: losslessly encodes PNG once, entirely in Rust.
    /// MIME/record image entries never pass through this encoder.
    pub async fn write_image(&self, rgba: &[u8], width: u32, height: u32) -> Result<()> {
        let expected = (width as usize)
            .checked_mul(height as usize)
            .and_then(|size| size.checked_mul(4))
            .ok_or_else(|| invalid("clipboard image dimensions overflow"))?;
        if width == 0 || height == 0 || rgba.len() != expected {
            return Err(invalid(
                "clipboard RGBA length must equal nonzero width * height * 4",
            ));
        }
        let mut bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut bytes, width, height);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder.write_header().map_err(native_error)?;
            writer.write_image_data(rgba).map_err(native_error)?;
            writer.finish().map_err(native_error)?;
        }
        self.write_encoded_image(&bytes).await
    }

    pub async fn write_uris(&self, uris: Vec<String>) -> Result<()> {
        self.write_records(
            uris.into_iter()
                .map(|uri| ClipboardRecord {
                    uri: Some(uri),
                    ..Default::default()
                })
                .collect(),
        )
        .await
    }

    pub async fn clear(&self) -> Result<()> {
        native_board()?.clear().map_err(native_error)
    }

    fn project_record(&self, entries: Vec<Entry>) -> Result<Option<ClipboardRecord>> {
        let value = |mime: &str| entries.iter().find(|entry| entry.format == mime);
        let mut record = ClipboardRecord::default();
        if let Some(text) = value("text/plain") {
            record.text = Some(utf8(text.bytes.clone(), "text/plain")?);
            if let Some(metadata) = self
                .metadata_mime_type
                .as_ref()
                .and_then(|mime| value(mime))
            {
                record.metadata = Some(utf8(metadata.bytes.clone(), &metadata.format)?);
            }
        } else if let Some(image) = entries
            .iter()
            .find(|entry| entry.format.starts_with("image/"))
        {
            record.encoded_image = Some(image.bytes.clone());
        } else if let Some(uri) = value("text/uri-list") {
            let uri = utf8(uri.bytes.clone(), "text/uri-list")?;
            validate_uri(&uri)?;
            record.uri = Some(uri);
        } else {
            return Ok(None);
        }
        Ok(Some(record))
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

fn require_api(required: i32) -> Result<()> {
    if openharmony_ability::version::sdk_api_version() < required {
        return Err(ClipboardError::ApiUnavailable { required });
    }
    Ok(())
}

fn native_board() -> Result<Pasteboard> {
    require_api(13)?;
    Ok(Pasteboard::new())
}

fn write_native(records: Vec<Vec<NativeEntry>>) -> Result<()> {
    let board = native_board()?;
    let mut data = UdmfData::try_new().map_err(native_error)?;
    // Keep source owners alive until SetData returns, independent of whether
    // AddRecord copies or borrows its input on a particular SDK release.
    let mut owners = Vec::with_capacity(records.len());
    for entries in records {
        let record = UdmfRecord::try_new().map_err(native_error)?;
        for entry in entries {
            match entry {
                NativeEntry::PlainText(text) => {
                    let uds = UdsPlainText::new();
                    uds.set_content(&text)
                        .map_err(|error| text_error(error, &text, "text/plain"))?;
                    record
                        .add(uds.into())
                        .map_err(|error| text_error(error, &text, "text/plain"))?;
                }
                NativeEntry::Html(html) => {
                    let uds = UdsHtml::new();
                    uds.set_html(&html)
                        .map_err(|error| text_error(error, &html, "text/html"))?;
                    record
                        .add(uds.into())
                        .map_err(|error| text_error(error, &html, "text/html"))?;
                }
                NativeEntry::Bytes(entry) => {
                    record
                        .add_general_entry(&entry.format, &entry.bytes)
                        .map_err(native_error)?;
                }
            }
        }
        data.add_record(&record).map_err(native_error)?;
        owners.push(record);
    }
    board.set_data(&data).map_err(native_error)
}

struct NativeSnapshot {
    records: Vec<Vec<Entry>>,
    available: Vec<String>,
}

fn read_native(
    board: &Pasteboard,
    requested: Option<&[String]>,
    list: bool,
) -> Result<NativeSnapshot> {
    let mut data = board.data().map_err(|error| {
        ClipboardError::Native(format!(
            "native clipboard read failed: {error}; check READ_PASTEBOARD and signing profile ACL"
        ))
    })?;
    let available = if list {
        mime::available(
            data.types()
                .map_err(native_error)?
                .iter()
                .map(String::as_str),
        )
    } else {
        Vec::new()
    };
    let records = data.records().map_err(native_error)?;
    if records.is_empty() && board.has_data() {
        return Err(ClipboardError::AuthorizationRequired);
    }
    let mut result = Vec::with_capacity(records.len());
    for record in records {
        let mut entries = Vec::new();
        for format in record.types().map_err(native_error)? {
            if requested
                .is_some_and(|mimes| !mimes.iter().any(|mime| mime::native_type(mime) == format))
            {
                continue;
            }
            if let Some(entry) = mime::read_entry(
                &format,
                || {
                    record
                        .plain_text()
                        .map_err(native_error)?
                        .get_content()
                        .map_err(native_error)
                },
                || {
                    record
                        .html()
                        .map_err(native_error)?
                        .get_html()
                        .map_err(native_error)
                },
                |format| record.general_entry(format).map_err(native_error),
            ) {
                entries.push(entry);
            }
        }
        result.push(entries);
    }
    Ok(NativeSnapshot {
        records: result,
        available,
    })
}

fn invalid(message: &str) -> ClipboardError {
    ClipboardError::InvalidContent(message.into())
}

fn native_error(error: impl std::fmt::Display) -> ClipboardError {
    ClipboardError::Native(error.to_string())
}

fn text_error(error: impl std::fmt::Display, text: &str, mime: &str) -> ClipboardError {
    if text.is_empty() {
        ClipboardError::EmptyBinaryUnsupported { mime: mime.into() }
    } else {
        native_error(error)
    }
}

fn utf8(bytes: Vec<u8>, mime: &str) -> Result<String> {
    String::from_utf8(bytes).map_err(|_| ClipboardError::InvalidText { mime: mime.into() })
}

fn validate_uri(uri: &str) -> Result<()> {
    if !uri.starts_with("file://") || uri.contains('\0') {
        return Err(invalid("clipboard URI must be a file:// URI without NUL"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn retained_value_types_keep_their_names() {
        assert_eq!(ClipboardRecord::TYPE_NAME, "ohos.clipboard.Record");
        assert_eq!(
            ClipboardMimeContent::TYPE_NAME,
            "ohos.clipboard.MimeContent"
        );
        assert_eq!(
            ClipboardReadMimeResponse::TYPE_NAME,
            "ohos.clipboard.ReadMimeResponse"
        );
        assert_eq!(
            ClipboardReadContentResponse::TYPE_NAME,
            "ohos.clipboard.ReadContentResponse"
        );
        assert_eq!(ClipboardBridgePlugin::ID, "ohos.clipboard");
        assert_eq!(
            ClipboardBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }

    #[test]
    fn metadata_configuration_is_explicit_and_custom() {
        assert!(ClipboardClient::default()
            .with_metadata_mime_type("application/x-editor")
            .is_ok());
        for mime in [
            "",
            "text/plain",
            "bad",
            "application/x;parameter",
            "image/png",
        ] {
            assert!(ClipboardClient::default()
                .with_metadata_mime_type(mime)
                .is_err());
        }
    }
}
