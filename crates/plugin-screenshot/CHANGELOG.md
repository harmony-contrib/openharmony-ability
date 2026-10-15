# 1.0.0-beta.3

- Introduce `ScreenshotExt` and a worker-safe client for capturing a WebView viewport as a
  base64 PNG and reading a pixel as RGBA.
- Expose image dimensions and typed unknown-WebView, unavailable-snapshot and internal errors.
- Delegate to `ohos.webview` named actions; this Rust-only facade requires the WebView plugin
  and has no separate ArkTS factory.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
