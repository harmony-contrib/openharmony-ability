# 1.0.0-beta.3

- Introduce the `ohos.clipboard` async facade for text, HTML, RGBA/encoded images, URI lists,
  ordered clipboard records and clearing clipboard contents.
- Support text-record metadata and clipboard-change revision tracking through named N-API events.
- Validate record batches and image data; metadata interoperability is configured by the
  ArkTS factory's application-specific MIME type.
- Surface blocked-read diagnostics for `ohos.permission.READ_PASTEBOARD` and signing-profile ACLs.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
