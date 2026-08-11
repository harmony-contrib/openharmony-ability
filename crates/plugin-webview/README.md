# openharmony-ability-plugin-webview

`openharmony-ability-plugin-webview` 是 ArkWeb/WebView 的 Rust facade。它与
`@ohos-rs/ability-plugin-webview` HAR 成对工作：ArkTS 持有 `WebviewController`、ArkUI `FrameNode` 和
ArkWeb delegate；Rust 只持有 controller ID、具名 N-API 数据及 Rust-owned callback/protocol closure。

插件不把 WebView 写进 framework 的 `DefaultXComponent`。默认情况下 WebView 的 `FrameNode` 挂进
当前 native module 唯一组件的根树（全屏）；需要组合时，`parent_node(handle)` 把它挂到
`ohos.node` 容器句柄之下，从而保留 WebView、XComponent 和自定义 ArkUI 节点的混合布局。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-webview` |
| ArkTS HAR | `@ohos-rs/ability-plugin-webview` |
| 插件 ID | `ohos.webview` |
| 执行模式 | 异步：`AsyncBridge` / `invokeAsync` |
| 前置 context | `ui-context` |
| 挂载 | 当前 module/component 根树（默认全屏）；可选 `parentHandle` 挂到 `ohos.node` 容器 |
| 核心 action | `create`、控制器操作、`evaluate-script` |

所有出站 action 和所有 ArkWeb 反向事件都是具名 N-API 契约，不使用 JSON。`create` 返回 controller
ID；之后通过 `WebviewHandle` 操作控制器，而不是跨线程保存 ArkTS controller/object。

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

应用侧在 `oh-package.json5` 添加 `@ohos-rs/ability-plugin-webview`，并在 `NativeAbility` 中通过
`LazyPlugin` 显式装配新实例：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { WebviewPlugin } from "@ohos-rs/ability-plugin-webview";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new WebviewPlugin())];
}
```

HAR 的 ArkTS 运行时、挂载和 delegate 说明见 [ArkTS README](../../plugins/webview/README.md)。

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

组合到 RS 层节点树：先用内置 `ohos.node` 插件建容器，把 WebView 作为子节点挂进去，再整体挂根：

```rust
use openharmony_ability::{NodeExt, OpenHarmonyApp};
use openharmony_ability_plugin_webview::{WebviewCreateRequest, WebviewExt};

async fn composed_webview(app: &OpenHarmonyApp) -> Result<()> {
    let container = app.node()?.create_container().await?;
    app.webview()?
        .create(
            WebviewCreateRequest::new("article")
                .parent_node(container)
                .url("https://example.com"),
        )
        .await?;
    app.node()?.mount_into_root(container).await?;
    Ok(())
}
```

`WebviewCreateRequest` 支持 URL/HTML、`parent_node` 组合、样式、JavaScript 开关、devtools、
user agent、autoplay、document-start initialization scripts、headers 和 `transparent`。
`transparent(true)` 是创建时语义：若没有显式 background color，ArkTS 使用透明背景；显式颜色优先。

`WebviewHandle` 提供 `set_visible`、`set_background_color`、`load_url`、
`load_url_with_headers`、`load_html`、`url`、`set_zoom`、`reload`、`focus`、`cookies_with_url`、
`clear_all_browsing_data`、`remove`/`dispose` 和 `evaluate_script`。这些都是异步控制器 action。

## 挂载与生命周期

- 一个 `DefaultXComponent` 对应一个 native module；跨窗口的第二个组件必须使用另一个 module，
  `WebviewCreateRequest` 不接受 window/surface key。
- 同一个 module/component 可用不同 WebView ID 同时创建多个实例；每个实例拥有独立 mount key 和
  controller，同 ID recreate 才替换旧实例。ID 只在当前 module 内唯一；ArkTS 会生成进程唯一的
  内部 ArkWeb tag，跨 module 使用相同业务 ID 不会冲突。
- 默认全屏挂入当前 component 根树；需要组合时用 `parent_node(container)` 把 WebView 挂到
  `ohos.node` 容器之下（容器最终也由 Rust 决定挂不挂根）。
- 异步 `create` 等待 controller attach 和首次导航启动；等待由 lifecycle/cancel 驱动，不使用
  固定 timer 轮询。
- UI/Ability 销毁、调用超时或取消时，ArkTS 必须卸载临时节点和 controller 映射；Rust 不保存
  `UIContext`、`FrameNode`、`WebviewController` 或 ArkTS function。

## WebView 回调

在 `create` 前用 `WebviewCallbacksBuilder` 按 module-local WebView ID 声明回调：

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
变更是通知型事件。每个事件还携带内部 `native_tag`，facade 会先校验它仍是该业务 ID 的当前
controller；same-ID recreate 前的延迟事件不能命中新实例。所有 callback 在当前 N-API callback 内
运行，应快速返回；耗时工作只能复制数据后投递给 worker。

`ui-context-destroy` / `ability-destroy` 会兜底清空 controller attachment/tag 状态，但保留 callback、
protocol 和 proxy 声明，供同 module 后续 appearance 重建 controller。该兜底不依赖 closing 阶段还能
成功执行 ArkTS → Rust 清理通知。

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

`WebviewProtocol::register` 的新声明只能在进程级 engine 初始化前调用。不同 native module 拥有
独立 Rust 状态，但共享 ArkWeb engine；第一个 WebView create 会让所有已激活且装配该插件的 module
先 flush 声明，再初始化 engine。Ability 重建时重复相同 scheme + options 是幂等操作；engine 启动
后才加载的 module 只能复用进程已注册且 options 相同的 scheme，不能再新增 custom scheme。ID handler 和 JS proxy 应优先在 `create`
前声明；controller attach 后插件会先安装 protocol/proxy/delegate，再开始首次导航。需要异步回复
custom protocol 时使用 `custom_protocol_async` / `WebviewProtocolResponder`。

完整的 typeName、反向事件、线程、挂载和验收规则见
[插件开发规范](../../docs/plugin-development-standard.md)。
