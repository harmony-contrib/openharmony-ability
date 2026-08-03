# openharmony-ability-plugin-webview

`openharmony-ability-plugin-webview` 是 ArkWeb/WebView 的 Rust facade。它与
`@ohos-rs/plugin-webview` HAR 成对工作：ArkTS 持有 `WebviewController`、ArkUI `FrameNode` 和
ArkWeb delegate；Rust 只持有 controller ID、具名 N-API 数据及 Rust-owned callback/protocol closure。

插件不把 WebView 写进 framework 的 `DefaultXComponent`。默认情况下它挂载到通用
`xcomponent-overlay` slot；业务也可用 `BridgeNodeHost` 提供任意命名 slot，从而保留 WebView、
XComponent 和自定义 ArkUI 节点的混合布局。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-webview` |
| ArkTS HAR | `@ohos-rs/plugin-webview` |
| 插件 ID / bridge 版本 | `ohos.webview` / `1` |
| 执行模式 | 异步：`AsyncBridge` / `invokeAsync` |
| 前置 context | `ui-context` |
| 默认 slot | `xcomponent-overlay` |
| 核心 action | `create`、控制器操作、`evaluate-script` |

所有出站 action 和所有 ArkWeb 反向事件都是具名 N-API 契约，不使用 JSON。`create` 返回 controller
ID 和 slot ID；之后通过 `WebviewHandle` 操作控制器，而不是跨线程保存 ArkTS controller/object。

## 接入与注册

在 `#[ability]` 初始化期间注册 Rust facade；如需自定义 scheme，必须在 Web engine 初始化之前调用
`WebviewProtocol::register`：

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_webview::{
    WebviewBridgePlugin, WebviewProtocol, WebviewProtocolOptions,
};

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    WebviewProtocol::register("asset", WebviewProtocolOptions::Standard)
        .expect("scheme must be declared before Web engine initialization");
    app.register_plugin(WebviewBridgePlugin)
        .expect("webview facade must be registered once");
}
```

应用侧在 `oh-package.json5` 添加 `@ohos-rs/plugin-webview`，并在 `NativeAbility` 中显式装配 factory：

```ts
import { NativeAbility } from "@ohos-rs/ability";
import { createWebviewPlugin } from "@ohos-rs/plugin-webview";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [createWebviewPlugin()];
}
```

HAR 的 ArkTS 运行时、slot 和 delegate 说明见 [ArkTS README](../../plugins/webview/README.md)。

## 创建与控制 WebView

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_webview::{WebviewCreateRequest, WebviewExt};

async fn open_article(app: &OpenHarmonyApp) -> Result<()> {
    let client = app.webview()?;
    let handle = client
        .create(
            WebviewCreateRequest::new("article")
                .slot_id("webview-panel")
                .transparent(true)
                .url("https://example.com"),
        )
        .await?;

    handle.set_visible(true).await?;
    let title = handle.evaluate_script("document.title").await?;
    tracing::info!(?title, "page title");
    Ok(())
}
```

`WebviewCreateRequest` 支持 URL/HTML、slot、样式、JavaScript 开关、devtools、user agent、autoplay、
document-start initialization scripts、headers 和 `transparent`。`transparent(true)` 是创建时语义：若
没有显式 background color，ArkTS 使用透明背景；显式颜色优先。

`WebviewHandle` 提供 `set_visible`、`set_background_color`、`load_url`、
`load_url_with_headers`、`load_html`、`url`、`set_zoom`、`reload`、`focus`、`cookies_with_url`、
`clear_all_browsing_data`、`remove`/`dispose` 和 `evaluate_script`。这些都是异步控制器 action。

## slot 与生命周期

- `DefaultXComponent` 已提供默认 slot；需要业务自定义位置时，在页面使用
  `BridgeNodeHost({ moduleName, slotId, underlay, foreground })`，并把同一 `slotId` 写入 create request。
- 异步 `create` 可以等待 slot attach、controller attach 和首次导航启动；等待由 lifecycle/cancel
  驱动，不使用固定 timer 轮询。
- UI/Ability 销毁、调用超时或取消时，ArkTS 必须卸载临时节点和 controller 映射；Rust 不保存
  `UIContext`、`FrameNode`、`WebviewController` 或 ArkTS function。

## WebView 回调

在 `create` 前用 `WebviewCallbacksBuilder` 按 WebView tag 声明回调：

```rust
use openharmony_ability_plugin_webview::{
    WebviewCallbacksBuilder, WebviewDownloadStartResponse,
};

WebviewCallbacksBuilder::new("article")
    .on_navigation_request(|request| request.url.starts_with("app://blocked"))
    .on_download_start(|request| WebviewDownloadStartResponse::allow(request.temp_path))
    .on_download_end(|event| tracing::info!(?event, "download completed"))
    .on_title_change(|event| tracing::info!(?event, "title changed"))
    .build()?;
```

ArkTS 只接收“是否订阅”的创建快照，实际 closure 始终在 Rust。导航回调未订阅或失败时默认
`intercept = false`（fail-open）；下载开始回调未订阅时默认取消下载（fail-closed）；下载结束和标题
变更是通知型事件。所有 callback 在当前 N-API callback 内运行，应快速返回；耗时工作只能复制数据后
投递给 worker。

## 自定义 protocol 与页面 JavaScript

自定义 scheme 和页面 JavaScript proxy 是不同机制：

```rust
use std::borrow::Cow;
use openharmony_ability_plugin_webview::{
    WebviewJavascriptProxyBuilder, WebviewProtocol, WebviewProtocolOptions,
};

// 在 #[ability] 初始化器中：
WebviewProtocol::register("asset", WebviewProtocolOptions::Standard)?;

// 在 create 前：
client.custom_protocol("article", "asset", |_url, _request, _is_main_frame| {
    http::Response::builder()
        .header("content-type", "text/html")
        .body(Cow::Borrowed(&b"<h1>local page</h1>"[..]))
        .ok()
})?;

WebviewJavascriptProxyBuilder::new("article", "native")
    .add_method("postMessage", |_tag, arguments| {
        tracing::info!(?arguments, "page message");
    })
    .build()?;
```

`WebviewProtocol::register` 只能在 engine 初始化前调用。tag handler 和 JS proxy 应优先在 `create`
前声明；controller attach 后插件会先安装 protocol/proxy/delegate，再开始首次导航。需要异步回复
custom protocol 时使用 `custom_protocol_async` / `WebviewProtocolResponder`。

完整的 typeName、反向事件、线程、slot 和验收规则见
[插件开发规范](../../docs/plugin-development-standard.md)。
