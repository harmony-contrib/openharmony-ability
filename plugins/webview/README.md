# @ohos-rs/ability-plugin-webview

这是 `openharmony-ability-plugin-webview` 的 ArkTS HAR。它创建 ArkWeb `Web` / `WebviewController`、
把 WebView 的 `FrameNode` 挂进当前 native module 对应组件的根树（或 `ohos.node` 容器），并把所有
controller 操作和 ArkWeb callback 转换为具名 N-API bridge 调用。

业务不直接保存 controller，也不应把 WebView 接口重新写回 `DefaultXComponent`。Rust facade 使用
controller ID 操作 WebView；布局由业务页面 `Stack` 声明顺序决定。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-webview
```

## 装配

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.0",
    "@ohos-rs/ability-plugin-webview": "1.0.0-beta.0",
  },
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { WebviewPlugin } from "@ohos-rs/ability-plugin-webview";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new WebviewPlugin())];
}
```

Rust 侧必须在 `#[ability]` 初始化器注册 `WebviewBridgePlugin`；自定义 scheme 也必须在该阶段通过
`WebviewProtocol::register` 声明。完整 Rust 用法见
[Rust facade README](../../crates/plugin-webview/README.md)。

## Plugin 与 action

| 项目             | 值                                                                                                                                                                                   |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `id`             | `ohos.webview`                                                                                                                                                                       |
| `execution`      | `async`                                                                                                                                                                              |
| `requires`       | `["ui-context"]`                                                                                                                                                                     |
| 挂载             | 当前 module/component 根树（默认全屏）；可选 `parentHandle`（`ohos.node` 容器）                                                                                                    |
| 创建             | `create`：`CreateRequest { id, parentHandle? }` → `CreateResponse { id }`                                                                                                            |
| 控制器操作       | `set-visible`、`set-background-color`、`remove`、`load-url`、`load-html`、`set-zoom`、`reload`、`focus`、`get-url`、`cookies-with-url`、`clear-all-browsing-data`、`evaluate-script` |

所有 action 都校验 `BridgeTypedValue.typeName`，并只返回对应的具名 response。创建会等待
controller attach、delegate/protocol/proxy 安装和首次 load 启动；它不是“提交一个未来渲染任务”后
立刻成功。

## 挂载与混合布局

WebView 的 `FrameNode` 默认以 host 内部唯一 key 挂进当前 module 的组件根树，
全屏显示。Rust 需要组合时，先用内置 `ohos.node` 插件创建容器，把容器句柄作为 `parentHandle` 传入
create request，WebView 节点就会挂到该容器下；容器最终由 Rust `mount-into-root` 整体挂载。

业务层级 = 页面 `Stack` 声明顺序，业务内容放在 `DefaultXComponent` 前后即可得到下/上层级：

```ts
Stack() {
  this.BusinessUnderlay()                        // 插件树之下
  DefaultXComponent({ moduleName: "demo_native" })
  this.BusinessForeground()                      // 插件树之上
}
```

一个 `DefaultXComponent` 必须使用一个独立 native module；跨窗口组件不能共享 module，也不使用
`windowKey`/`surfaceKey`。同一 module/component 可按不同 ID 同时持有多个 WebView。WebView ID 是
不透明、facade-local 的业务标识，不会直接拼接成节点 key 或进程级 ArkWeb tag；HAR 会用
session + 进程计数器生成内部唯一 native tag，因此同一进程的多个插件实例可安全复用同一业务 ID。

节点挂载没有计时等待：module 根在 `ui-context-ready` 前已存在，`onInstall` 后即可挂载。
Ability/session dispose 时，HAR 必须卸载自己创建的节点与 controller 状态（`remove` 走
`context.removeChild` 或从父容器摘除），不能影响业务节点或其他插件。

## ArkWeb callback、custom protocol 与 JS

- Rust 在 `create` 前声明 callback 订阅；HAR 依据订阅快照安装 ArkWeb delegate。导航请求、下载开始、
  下载结束、标题变化、engine/controller lifecycle 全部通过
  `context.invokeNativeSync` 回到 Rust `on_main_thread_event`。
- 导航未订阅或 callback 出错时 fail-open（不拦截）；下载开始未订阅或出错时 fail-closed（取消下载）。
  下载结束、标题等通知型 callback 只记录失败。所有 controller 平台事件同时携带内部 native tag；
  Rust 会先校验当前 ID 对应的 controller generation，旧实例的延迟导航回调 fail-open、下载开始
  fail-closed，通知型回调直接丢弃。
- custom scheme 必须在进程级 engine 初始化前注册；第一个 WebView create 会在初始化前后向所有已
  激活、装配本插件的 Rust facade 广播具名 engine 事件，先 seal、聚合校验并 flush 各自的 Rust
  scheme 状态。Ability 重建时可幂等重复相同 scheme + options；engine 启动后新增 scheme 会确定性
  失败；后加载 facade 只能复用已注册且 options 完全相同的 scheme；不同 facade 对同名 scheme
  声明不同 options 时也会在 engine 初始化前失败。
  controller attach 后先安装 tag 对应的 protocol、JS proxy 与 delegate，再进行首次导航。
- URL custom protocol 与 `window.<object>.<method>()` JavaScript proxy 是不同机制；前者处理资源请求，
  后者处理页面到 Rust 的方法调用。
- `.transparent(true)` 的创建语义由 `CreateRequest` 保留：没有显式 background color 时使用透明背景。

完整的反向 typeName、线程、生命周期、节点清理与验收条件见
[插件开发规范](../../docs/plugin-development-standard.md)。
