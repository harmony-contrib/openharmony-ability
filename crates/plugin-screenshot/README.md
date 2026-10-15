# openharmony-ability-plugin-screenshot

English | [简体中文](README.zh-CN.md)

Capture a WebView's visible viewport or read a snapshot pixel color. This facade reuses the named actions of `ohos.webview`; it has no separate ArkTS HAR or plugin factory.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-screenshot` |
| Platform plugin | `ohos.webview` |
| action | `capture-webview` / `pick-color` |
| Execution | Async; requires the WebView plugin and its UI context |

## Integration

```toml
[dependencies]
openharmony-ability-plugin-screenshot = "1.0.0-beta.3"
openharmony-ability-plugin-webview = "1.0.0-beta.3"
```

Follow the [WebView Rust README](../plugin-webview/README.md) to register `WebviewBridgePlugin` and install [`WebviewPlugin`](../../plugins/webview/README.md) on the ArkTS side. Create the target controller before capturing it by its module-local WebView ID.

## Rust usage

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_screenshot::{CapturedImage, ScreenshotExt};

async fn capture(app: &OpenHarmonyApp, webview_id: &str) -> Result<CapturedImage> {
    let screenshot = app.screenshot()?;
    Ok(screenshot.capture_webview(webview_id).await?)
}
```

| API | Result |
| --- | --- |
| `capture_webview(id)` | `CapturedImage { png_base64, width, height }` |
| `pick_color(id, x, y)` | `Rgba { r, g, b, a }` |

## Behavior and constraints

- Capture includes the visible WebView viewport, not the full scrollable document, window or screen. Color coordinates use snapshot pixels.
- `capture_webview` returns a base64 PNG; color channels range from 0 to 255. Out-of-bounds coordinates fail.
- Failures return `ScreenshotError`, distinguishing `UnknownWebview`, `SnapshotUnavailable` and `Internal`.
- Methods are asynchronous; do not block the N-API main thread waiting for them. ArkTS reads/releases the PixelMap within the operation; Rust retains no platform image object.

See the [Rust source](src/lib.rs).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
