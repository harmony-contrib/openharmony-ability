# Unreleased — D4 native-only clipboard (breaking)

- Use only native `OH_Pasteboard` and scoped UDMF owners. Withdraw all ArkTS clipboard
  actions, change events, permission prompts and legacy metadata fallback.
- Retain `read_records`, `write_records`, `read_mime`, `write_mime` and convenience
  methods as async-shaped synchronous native operations, with typed `ClipboardError`.
- Move metadata configuration to Rust `with_metadata_mime_type`; the paired HAR now
  takes no options and supplies registration identity only.
- Preserve opaque nonempty MIME bytes and multiple encoded images without PixelMap
  conversion. Use typed UDS for plain text/HTML, including empty strings when accepted.
  NUL/non-UTF-8 text is rejected; empty opaque data returns `EmptyBinaryUnsupported`
  because `OH_UdmfRecord_AddGeneralEntry` rejects `count == 0`. No private encoding.
- `read_authorized_records` returns `AuthorizationRequired`; callers obtain permission
  explicitly before ordinary reads. `revision() -> Result<u32>` pulls the API-18 native
  counter; enable `api-18`, handle zero as unknown and allow service-reset decreases.
- Pin bindings PR #187 until released; Rust and HAR must be upgraded together.

# 1.0.0-beta.3

- Introduce the `ohos.clipboard` async facade for text, HTML, RGBA/encoded images, URI lists,
  ordered clipboard records and clearing clipboard contents.
- Support text-record metadata and clipboard-change revision tracking through named N-API events.
- Validate record batches and image data; metadata interoperability is configured by the
  ArkTS factory's application-specific MIME type.
- Surface blocked-read diagnostics for `ohos.permission.READ_PASTEBOARD` and signing-profile ACLs.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
