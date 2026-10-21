//! Clipboard format policy, independent of native owners and the N-API runtime.

use std::{collections::HashSet, fmt};

pub const MAX_REPRESENTATIONS: usize = 512;
pub const MAX_MIME_BYTES: usize = 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClipboardError {
    InvalidContent(String),
    EmptyBinaryUnsupported { mime: String },
    InvalidText { mime: String },
    AuthorizationRequired,
    ApiUnavailable { required: i32 },
    RevisionUnavailable,
    Native(String),
}

impl fmt::Display for ClipboardError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidContent(message) | Self::Native(message) => f.write_str(message),
            Self::EmptyBinaryUnsupported { mime } => {
                write!(
                    f,
                    "native clipboard cannot store an empty binary representation ({mime})"
                )
            }
            Self::InvalidText { mime } => {
                write!(f, "{mime} requires UTF-8 text without embedded NUL")
            }
            Self::AuthorizationRequired => f.write_str(
                "clipboard authorization must be obtained by the application before read_records; \
                 check READ_PASTEBOARD and the signing profile ACL",
            ),
            Self::ApiUnavailable { required } => {
                write!(
                    f,
                    "native clipboard requires OpenHarmony API {required} or later"
                )
            }
            Self::RevisionUnavailable => {
                f.write_str("native clipboard revision is unknown (change count is zero)")
            }
        }
    }
}

impl std::error::Error for ClipboardError {}

pub type Result<T> = std::result::Result<T, ClipboardError>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub format: String,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NativeEntry {
    PlainText(String),
    Html(String),
    Bytes(Entry),
}

const FORMATS: &[(&str, &str)] = &[
    ("text/plain", "general.plain-text"),
    ("text/html", "general.html"),
    ("text/uri-list", "general.file-uri"),
    ("image/png", "general.png"),
    ("image/jpeg", "general.jpeg"),
    ("image/gif", "general.gif"),
    ("image/webp", "general.webp"),
    ("image/bmp", "com.microsoft.bmp"),
    ("image/tiff", "general.tiff"),
    ("image/svg+xml", "general.svg"),
];

pub fn native_type(mime: &str) -> &str {
    FORMATS
        .iter()
        .find_map(|(candidate, native)| (*candidate == mime).then_some(*native))
        .unwrap_or(mime)
}

pub fn mime_type(native: &str) -> &str {
    FORMATS
        .iter()
        .find_map(|(mime, candidate)| (*candidate == native).then_some(*mime))
        .unwrap_or(native)
}

pub fn validate_mimes<'a>(mimes: impl ExactSizeIterator<Item = &'a str>) -> Result<()> {
    if mimes.len() > MAX_REPRESENTATIONS
        || mimes
            .into_iter()
            .any(|mime| mime.is_empty() || mime.len() > MAX_MIME_BYTES || mime.contains('\0'))
    {
        return Err(ClipboardError::InvalidContent(
            "invalid clipboard MIME representations".into(),
        ));
    }
    Ok(())
}

pub fn encode(entries: Vec<Entry>) -> Result<Vec<NativeEntry>> {
    validate_mimes(entries.iter().map(|entry| entry.format.as_str()))?;
    let mut seen = HashSet::new();
    let mut result = Vec::with_capacity(entries.len());
    for entry in entries {
        let format = native_type(&entry.format).to_owned();
        if !seen.insert(format.clone()) {
            return Err(ClipboardError::InvalidContent(
                "duplicate clipboard representation after MIME/UTD mapping".into(),
            ));
        }
        result.push(match format.as_str() {
            "general.plain-text" | "general.html" => {
                let text = String::from_utf8(entry.bytes)
                    .ok()
                    .filter(|text| !text.contains('\0'))
                    .ok_or(ClipboardError::InvalidText { mime: entry.format })?;
                if format == "general.plain-text" {
                    NativeEntry::PlainText(text)
                } else {
                    NativeEntry::Html(text)
                }
            }
            _ if entry.bytes.is_empty() => {
                // OH_UdmfRecord_AddGeneralEntry rejects count == 0.
                return Err(ClipboardError::EmptyBinaryUnsupported { mime: entry.format });
            }
            _ => NativeEntry::Bytes(Entry {
                format,
                bytes: entry.bytes,
            }),
        });
    }
    Ok(result)
}

/// Requested order and spelling are preserved, including repeated requests.
pub fn select(records: &[Vec<Entry>], requested: &[String]) -> Vec<Entry> {
    requested
        .iter()
        .filter_map(|mime| {
            records
                .iter()
                .flatten()
                .find(|entry| native_type(&entry.format) == native_type(mime))
                .map(|entry| Entry {
                    format: mime.clone(),
                    bytes: entry.bytes.clone(),
                })
        })
        .collect()
}

pub fn available<'a>(formats: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    let mut seen = HashSet::new();
    formats
        .into_iter()
        .map(mime_type)
        .filter(|format| seen.insert((*format).to_owned()))
        .map(str::to_owned)
        .collect()
}

/// Typed UDS content and opaque general entries are different native layouts.
/// Failed/absent individual representations stay absent; never invent bytes.
pub fn read_entry(
    native: &str,
    plain_text: impl FnOnce() -> Result<String>,
    html: impl FnOnce() -> Result<String>,
    general: impl FnOnce(&str) -> Result<Vec<u8>>,
) -> Option<Entry> {
    let bytes = match native {
        "general.plain-text" => plain_text().ok()?.into_bytes(),
        "general.html" => html().ok()?.into_bytes(),
        _ => {
            let bytes = general(native).ok()?;
            if bytes.is_empty() {
                return None;
            }
            bytes
        }
    };
    Some(Entry {
        format: mime_type(native).into(),
        bytes,
    })
}

#[cfg(any(test, feature = "api-18"))]
pub fn revision(count: u32) -> Result<u32> {
    if count == 0 {
        Err(ClipboardError::RevisionUnavailable)
    } else {
        Ok(count)
    }
}

pub fn image_mime(bytes: &[u8]) -> Result<&'static str> {
    if bytes.is_empty() {
        Err(ClipboardError::EmptyBinaryUnsupported {
            mime: "image/*".into(),
        })
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Ok("image/png")
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        Ok("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Ok("image/gif")
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        Ok("image/webp")
    } else if bytes.starts_with(b"BM") {
        Ok("image/bmp")
    } else if bytes.starts_with(b"II\x2a\0") || bytes.starts_with(b"MM\0\x2a") {
        Ok("image/tiff")
    } else {
        Err(ClipboardError::InvalidContent(
            "unrecognized encoded image; use write_mime with an explicit image MIME".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(format: &str, bytes: &[u8]) -> Entry {
        Entry {
            format: format.into(),
            bytes: bytes.to_vec(),
        }
    }

    #[test]
    fn standard_and_custom_formats_round_trip() {
        for (mime, native) in FORMATS {
            assert_eq!(native_type(mime), *native);
            assert_eq!(mime_type(native), *mime);
        }
        assert_eq!(native_type("application/x-editor"), "application/x-editor");
        assert_eq!(mime_type("application/x-editor"), "application/x-editor");
    }

    #[test]
    fn exact_binary_multiple_images_and_nul_survive() {
        let input = vec![
            entry("image/png", b"\x89PNG\r\n\x1a\n\xff\0"),
            entry("image/jpeg", b"\xff\xd8\xff\0\x80"),
            entry("application/x-editor", &[0, 255, 128]),
        ];
        let native = encode(input.clone()).unwrap();
        for (native, original) in native.iter().zip(input) {
            let NativeEntry::Bytes(native) = native else {
                panic!("binary representations must remain general entries");
            };
            assert_eq!(native.bytes, original.bytes);
            assert_eq!(mime_type(&native.format), original.format);
        }
    }

    #[test]
    fn empty_text_is_present_and_distinct_from_an_empty_clipboard() {
        assert_eq!(
            encode(vec![entry("text/plain", b""), entry("text/html", b"")]).unwrap(),
            [
                NativeEntry::PlainText(String::new()),
                NativeEntry::Html(String::new())
            ]
        );
        let data = vec![vec![entry("text/plain", b"")]];
        assert_eq!(
            available(data.iter().flatten().map(|entry| entry.format.as_str())),
            ["text/plain"]
        );
        assert_eq!(
            select(&data, &["text/plain".into()]),
            [entry("text/plain", b"")]
        );
        assert!(select(&[], &["text/plain".into()]).is_empty());
    }

    #[test]
    fn selection_preserves_request_order_and_uses_first_record() {
        let records = vec![
            vec![
                entry("text/plain", b"first"),
                entry("application/x-bin", &[255]),
            ],
            vec![entry("text/plain", b"second")],
        ];
        let request = [
            "application/x-bin",
            "absent/type",
            "text/plain",
            "text/plain",
        ]
        .map(String::from);
        assert_eq!(
            select(&records, &request),
            [
                entry("application/x-bin", &[255]),
                entry("text/plain", b"first"),
                entry("text/plain", b"first"),
            ]
        );
        assert_eq!(
            available(records.iter().flatten().map(|entry| entry.format.as_str())),
            ["text/plain", "application/x-bin"]
        );
    }

    #[test]
    fn limits_count_bytes_and_reject_duplicate_entries() {
        assert!(validate_mimes(std::iter::repeat_n("text/plain", 512)).is_ok());
        assert!(validate_mimes(std::iter::repeat_n("text/plain", 513)).is_err());
        assert!(validate_mimes(std::iter::once("application/é")).is_ok());
        assert!(validate_mimes(std::iter::once("")).is_err());
        assert!(validate_mimes(std::iter::once("bad\0mime")).is_err());
        let valid = "é".repeat(512);
        assert!(validate_mimes(std::iter::once(valid.as_str())).is_ok());
        let invalid = format!("{valid}x");
        assert!(validate_mimes(std::iter::once(invalid.as_str())).is_err());
        assert!(encode(vec![
            entry("text/plain", b"a"),
            entry("general.plain-text", b"b")
        ])
        .is_err());
    }

    #[test]
    fn empty_binary_is_an_explicit_typed_error_not_a_fake_representation() {
        for mime in [
            "application/octet-stream",
            "image/png",
            "application/x-metadata",
        ] {
            assert_eq!(
                encode(vec![entry(mime, b"")]),
                Err(ClipboardError::EmptyBinaryUnsupported { mime: mime.into() })
            );
        }
        assert!(encode(vec![]).unwrap().is_empty());
    }

    #[test]
    fn typed_native_text_requires_lossless_c_string_content() {
        for mime in ["text/plain", "text/html"] {
            for invalid in [b"a\0b".as_slice(), &[255, 128]] {
                assert_eq!(
                    encode(vec![entry(mime, invalid)]),
                    Err(ClipboardError::InvalidText { mime: mime.into() })
                );
            }
        }
        assert_eq!(
            encode(vec![entry("text/plain", "Hello 世界".as_bytes())]).unwrap(),
            [NativeEntry::PlainText("Hello 世界".into())]
        );
    }

    #[test]
    fn native_read_dispatch_uses_typed_text_only_and_preserves_absence() {
        let plain = read_entry(
            "general.plain-text",
            || Ok(String::new()),
            || panic!("not HTML"),
            |_| panic!("never general-entry text"),
        );
        assert_eq!(plain, Some(entry("text/plain", b"")));
        let html = read_entry(
            "general.html",
            || panic!("not plain text"),
            || Ok("<b>html</b>".into()),
            |_| panic!("never general-entry HTML"),
        );
        assert_eq!(html, Some(entry("text/html", b"<b>html</b>")));
        let image = read_entry(
            "general.png",
            || panic!("not text"),
            || panic!("not HTML"),
            |native| {
                assert_eq!(native, "general.png");
                Ok(vec![255, 0, 128])
            },
        );
        assert_eq!(image, Some(entry("image/png", &[255, 0, 128])));
        assert!(read_entry(
            "general.png",
            || panic!(),
            || panic!(),
            |_| Err(ClipboardError::Native("absent".into())),
        )
        .is_none());
        assert!(read_entry(
            "application/x-empty",
            || panic!(),
            || panic!(),
            |_| Ok(vec![]),
        )
        .is_none());
        assert!(read_entry(
            "general.plain-text",
            || Err(ClipboardError::Native("unreadable".into())),
            || panic!(),
            |_| panic!("no fallback"),
        )
        .is_none());
    }

    #[test]
    fn native_revision_zero_is_unknown_and_counter_may_reset() {
        assert_eq!(revision(0), Err(ClipboardError::RevisionUnavailable));
        assert_eq!(revision(12), Ok(12));
        assert_eq!(revision(1), Ok(1));
    }

    #[test]
    fn encoded_images_are_identified_without_decoding_or_reencoding() {
        assert_eq!(image_mime(b"\x89PNG\r\n\x1a\n").unwrap(), "image/png");
        assert_eq!(image_mime(b"\xff\xd8\xff").unwrap(), "image/jpeg");
        assert_eq!(image_mime(b"GIF89a").unwrap(), "image/gif");
        assert_eq!(image_mime(b"RIFF\0\0\0\0WEBP").unwrap(), "image/webp");
        assert!(image_mime(b"not an image").is_err());
        assert_eq!(
            image_mime(b""),
            Err(ClipboardError::EmptyBinaryUnsupported {
                mime: "image/*".into()
            })
        );
    }
}
