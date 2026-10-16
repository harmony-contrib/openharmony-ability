# 1.0.0-beta.3

- Introduce the `ohos.clipboard` async plugin for text, HTML, images, URI lists and ordered
  multi-record clipboard content, with lifecycle-scoped change notifications.
- **Configuration**: require a `metadataMimeType` constructor option for text metadata;
  validate the custom MIME and preserve reads of legacy metadata formats.
- Validate record/image inputs and release temporary image resources after platform operations.
- Report unreadable clipboard data with permission/signing-profile ACL diagnostics instead
  of silently treating blocked reads as an empty clipboard.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
