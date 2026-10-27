# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- `ClipboardPlugin` is now a no-argument registration/lifecycle identity only.
  Remove `ClipboardPluginOptions` and move metadata configuration to Rust
  `ClipboardClient::with_metadata_mime_type`.
- Remove every ArkTS pasteboard action, observer, image codec and permission prompt.
  Old clipboard actions explicitly fail instead of falling back.
- Upgrade Rust and HAR from the same source revision. Rust uses native-only clipboard
  APIs with typed errors, API-18 pull revision, and no automatic authorization.
- Empty opaque representations return `ClipboardError::EmptyBinaryUnsupported`;
  empty plain text/HTML use typed native UDS. There is no private empty-value encoding.

## [1.0.0-beta.3]

- Introduce the `ohos.clipboard` async plugin for text, HTML, images, URI lists and ordered
  multi-record clipboard content, with lifecycle-scoped change notifications.
- **Configuration**: require a `metadataMimeType` constructor option for text metadata;
  validate the custom MIME and preserve reads of legacy metadata formats.
- Validate record/image inputs and release temporary image resources after platform operations.
- Report unreadable clipboard data with permission/signing-profile ACL diagnostics instead
  of silently treating blocked reads as an empty clipboard.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
