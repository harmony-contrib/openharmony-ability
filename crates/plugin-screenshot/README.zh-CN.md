# openharmony-ability-plugin-screenshot

[English](README.md) | 简体中文

捕获指定 WebView 的可见视口或读取快照像素颜色。它复用 `ohos.webview` 的具名 action，没有独立 ArkTS HAR 或插件 factory。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-screenshot` |
| 平台插件 | `ohos.webview` |
| action | `capture-webview` / `pick-color` |
| 执行模式 | 异步；需要 WebView 插件及其 UI context |

## 接入

```toml
[dependencies]
openharmony-ability-plugin-screenshot = "1.0.0-beta.3"
openharmony-ability-plugin-webview = "1.0.0-beta.3"
```

按 [WebView Rust README](../plugin-webview/README.zh-CN.md) 注册 `WebviewBridgePlugin`，并装配 [`WebviewPlugin`](../../plugins/webview/README.zh-CN.md)。先创建目标 controller，再使用同一 module 内的 WebView ID 调用截图。

## Rust 使用方式

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_screenshot::{CapturedImage, ScreenshotExt};

async fn capture(app: &OpenHarmonyApp, webview_id: &str) -> Result<CapturedImage> {
    let screenshot = app.screenshot()?;
    Ok(screenshot.capture_webview(webview_id).await?)
}
```

| API | 结果 |
| --- | --- |
| `capture_webview(id)` | `CapturedImage { png_base64, width, height }` |
| `pick_color(id, x, y)` | `Rgba { r, g, b, a }` |

## 行为与限制

- 截图只包含 WebView 可见视口，不是整个滚动页面、窗口或屏幕截图。坐标使用截图像素坐标系。
- `capture_webview` 返回 base64 PNG；颜色通道为 0–255。坐标越界会失败。
- controller 不存在、尚未产生可用快照或平台捕获失败时返回 `ScreenshotError`；错误类型区分 `UnknownWebview`、`SnapshotUnavailable` 和 `Internal`。
- 方法是异步的，不能在 N-API 主线程阻塞等待。PixelMap 在 ArkTS 操作内读取并释放，Rust 不持有平台图片对象。

完整 API 见 [Rust 源码](src/lib.rs).

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
