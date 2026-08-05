# OpenHarmony Ability 插件开发规范

> 适用于仓库内置插件和业务插件。本文中的“必须”表示合入条件，“应当”表示没有充分理由不得偏离。
> 本文是插件开发的唯一规范文档：从建包、契约定义、线程模型、生命周期、节点挂载到 WebView
> 扩展和验收均以本文为准，不依赖其他架构说明文档。

## 1. 目标与边界

插件是对某一项平台能力的成对封装：Rust 提供业务可调用、强类型的 facade；ArkTS HAR
持有 HarmonyOS 平台对象并实现真正的平台调用。框架 core 只提供通用的桥接 transport、线程
约束、生命周期和 ArkUI 节点插槽，**不得认识任何具体业务能力**。

一个插件从创建到交付必须按以下顺序完成：

1. 划定能力边界，确定它是异步能力还是必须立即返回的主线程同步能力，并列出它依赖的 context。
2. 建立 `crates/plugin-<name>` 与 `plugins/<name>` 成对包，先固定插件 ID、版本、action 和
   具名 request/response ABI。
3. 在 Rust 实现 `BridgePlugin` marker 与面向业务的扩展 trait/client；在 ArkTS 实现同一契约的
   `BridgePluginFactory`。
4. 将平台对象、生命周期监听、节点与 delegate 留在 ArkTS；将 worker-safe 数据、业务校验和
   Rust closure 留在 Rust。
5. 为 context 未就绪、调用取消、页面 detach、Ability 销毁和重复安装写出确定的处理路径。
6. 在 demo 中分别覆盖异步、主线程同步和（如有）原生节点/平台回调路径，再完成验收检查。

每个插件必须满足以下边界：

- Rust crate 位于 `crates/plugin-<name>`，只能依赖 `openharmony-ability`，不能依赖 ArkTS
  实现或应用页面；对外通过扩展 trait/client 暴露能力。
- ArkTS HAR 位于 `plugins/<name>`，只能依赖 `@ohos-rs/ability` 和需要的平台 Kit；导出一个
  `BridgePluginFactory`。
- 应用入口显式同时组合 Rust 插件 facade 与 ArkTS factory；core 不能反向 import 任意
  `plugin-*` crate/HAR。
- 一个插件只能管理自己的资源、回调和节点。布局、业务页面状态和其他插件资源仍由应用拥有。

目录骨架如下：

```text
crates/plugin-login/
  src/lib.rs                    # BridgePlugin、具名 N-API 类型、LoginExt facade、测试
plugins/login/
  src/main/ets/LoginPlugin.ets  # BridgePluginFactory、HarmonyOS API、生命周期释放
demo/                            # 显式注册 factory，并覆盖真实调用路径
```

历史 `helper/` 中属于某项平台能力的接口必须迁移到对应的成对插件中，不得在 core 新增
“万能 helper”。只有不包含平台能力契约的通用运行时设施（例如模块加载、通用调度）才可留在 core。

## 2. 插件身份与双端一致性

Rust `BridgePlugin` 和 ArkTS `BridgePluginFactory` 是同一个契约的两面。下列字段必须完全一致：

| 字段 | Rust | ArkTS | 规则 |
| --- | --- | --- | --- |
| 插件 ID | `BridgePlugin::ID` | `factory.id` / `plugin.id` | 使用稳定、小写、点分名称，例如 `ohos.permission` |
| 版本 | `BridgePlugin::VERSION` | `factory.version` / `plugin.version` | 任一 request/response 或 action 语义变化时双端同步升级 |
| 执行模式 | `type Mode` | `execution` | 只能是 async 或 sync-main-thread，不能由运行时布尔值决定 |
| context 前置条件 | `REQUIRED_CONTEXTS` | `requires` | 内容完全相同；不能只在一端声明 |

ID、action 和 type name 只能使用 `A-Za-z0-9._-`；action 使用 kebab-case 的动词短语，例如
`request`、`get-avoid-area`、`set-visible`。同一插件内 action 的语义不得因版本不同而悄悄改变。

### 2.1 通用桥接边界

插件不得自行发明 Rust ↔ ArkTS 通信通道。所有出站 action 都使用 core 提供的统一参数顺序：

```text
异步：bridgeInvoke(pluginId, version, action, requestType, responseType, value, timeoutMs)
同步：bridgeInvokeSync(pluginId, version, action, requestType, responseType, value)
入站：onBridgeSyncEvent(pluginId, event, requestType, responseType, value)
```

其中 `value` 是当前 `napi_env` 中的真实 N-API value；`requestType` 与 `responseType` 是稳定 ABI 名。
异步出站由 TSFN 将 ArkTS Promise 转成 Rust future：请求只在 ArkTS callback 中编码，响应也在该处
解码为 Rust 所有权数据后才回到 worker。同步出站 `bridgeInvokeSync` 默认只在当前活跃 N-API callback
内使用（`with_main_thread_bridge(...).call_sync`）；Rust worker 也可经 `call_sync_from_worker`
TSFN 通道调用同一函数，执行仍发生在 ArkTS 主线程（见 4.1）。入站事件只能在当前活跃的 N-API
callback 内完成。

C++ N-API 实现也必须使用上述同一边界，且只能在当前 `napi_env` 内创建、读取或返回
`napi_value`。禁止把 `napi_env`、`napi_value`、`napi_ref`、ArkTS object 或 function 放入 worker、
static、跨线程队列或长期缓存。

## 3. 请求与响应：具名 N-API 类型，不使用 JSON

所有插件 action 的 request 和 response 必须通过真实 N-API value 传输，并使用稳定的
`typeName` 作为 ABI 名称。禁止将对象序列化为 JSON 字符串后穿过桥接层，包括
`JSON.stringify` / `JSON.parse`、`BridgeJson`、`call_json`、`bridgeJson`、`requireBridgeJson`
及任何等价封装。

这条规则同样适用于 WebView 的导航、下载、标题等反向回调。当前插件桥没有面向新插件的
JSON event port；ArkTS 回调 Rust 应使用 `context.invokeNativeSync` 和具名类型。

### 3.1 Rust 侧

对象契约必须使用 `#[napi(object)]` 加 `impl_bridge_napi_type!` 固定名字。Rust 字段采用
snake_case，N-API 对象在 ArkTS 中按 camelCase 使用。

```rust
use napi_derive_ohos::napi;
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeContextRequirement, BridgePlugin,
};

pub struct LoginBridgePlugin;

impl BridgePlugin for LoginBridgePlugin {
    type Mode = AsyncBridge;
    const ID: &'static str = "account.login";
    const VERSION: u32 = 1;
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct LoginRequest {
    pub account_id: String,
}
impl_bridge_napi_type!(LoginRequest, "account.LoginRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct LoginResponse {
    pub token: String,
}
impl_bridge_napi_type!(LoginResponse, "account.LoginResponse");
```

`String`、`Vec<u8>` 和基础标量本身也是具名 N-API 类型：`std.string`、`std.bytes`、
`std.bool`、`std.i32`、`std.f64`。因此“string 也是一种类型”，无需为了统一接口再包一层 JSON。

每个公开对象必须有稳定、可读的类型名：内置插件以完整插件 ID 为前缀，例如
`ohos.permission.PermissionRequest`；业务插件使用 `<domain>.<TypeName>`，例如
`account.LoginRequest`。每个 request/response 至少要有单元测试断言 `BridgeNapiType::TYPE_NAME`。

### 3.2 ArkTS 侧

ArkTS 必须先校验传入 `typeName` 和对象形状，再调用平台 API；返回时必须填入对应的 response
`typeName`。不得因类型不匹配而静默降级或忽略字段。

```ts
const LOGIN_REQUEST_TYPE = "account.LoginRequest";
const LOGIN_RESPONSE_TYPE = "account.LoginResponse";

interface LoginRequest {
  accountId: string;
}

class LoginResponse {
  readonly token: string;

  constructor(token: string) {
    this.token = token;
  }
}

function parseLoginRequest(payload: BridgeTypedValue): LoginRequest {
  if (payload.typeName !== LOGIN_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`login requires bridge type ${LOGIN_REQUEST_TYPE}`);
  }
  const request = payload.value as LoginRequest;
  if (!request?.accountId?.trim()) {
    throw new Error("login.accountId must be non-empty");
  }
  return request;
}
```

完整的 ArkTS 实现还必须把 execution、requires 和 factory 固定下来。下面是异步登录插件的最小
骨架；真实平台调用完成后要再次检查 `context.isActive()`，防止 Ability 已销毁仍返回过期结果：

```ts
class LoginPlugin implements AsyncBridgePlugin {
  readonly id = "account.login";
  readonly version = 1;
  readonly execution: "async" = "async";
  readonly requires: ["ability"] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (action !== "login") {
      throw new Error(`Unsupported account.login action '${action}'`);
    }
    const request = parseLoginRequest(payload);
    const token = await loginWithPlatformApi(context.abilityContext, request.accountId);
    if (!context.isActive()) {
      throw new Error("Ability was destroyed while login was pending");
    }
    return { typeName: LOGIN_RESPONSE_TYPE, value: new LoginResponse(token) };
  }
}

export function createLoginPlugin(): BridgePluginFactory {
  return {
    id: "account.login",
    version: 1,
    execution: "async",
    requires: ["ability"],
    create: (_context: BridgePluginContext): AsyncBridgePlugin => new LoginPlugin(),
  };
}
```

### 3.3 既有内置插件的契约基线

迁移 helper 或新增 action 时，应以现有插件的类型名、模式和 context 作为兼容语义基线；只能在
双端升级版本后改变契约。

| 插件 / action | request → response | 模式 / context |
| --- | --- | --- |
| `ohos.app-control` / `terminate` | `ohos.app_control.TerminateRequest { code }` → `ohos.app_control.TerminateResponse { accepted }` | sync / `ability` |
| `ohos.permission` / `request` | `ohos.permission.PermissionRequest { permissions }` → `ohos.permission.PermissionResponse { codes }` | async / `ability` |
| `ohos.window` / `get-avoid-area` | `ohos.window.AvoidAreaRequest { areaType }` → `ohos.window.AvoidAreaResponse { area }` | sync / `window-stage` |
| `ohos.webview` / `create` | `ohos.webview.CreateRequest` → `ohos.webview.CreateResponse { id, slotId }` | async / `ui-context` |
| `ohos.webview` / 控制器 action | `ohos.webview.ControllerRequest` → `ohos.webview.Acknowledgement` / `StringResponse` / `ScriptResponse` | async / `ui-context` |
| `ohos.resource` / `resource-manager-ready`（入站） | `ohos.resource.ResourceManagerRef`（ArkTS 直接传 `resourceManager` 对象）→ `ohos.resource.ResourceManagerReadyResponse { accepted }` | 入站事件 / `ability` |

`resource` 是纯入站插件：ArkTS wrapper 在 `ability-create` 时经 `invokeNativeSync` 推送平台
对象，Rust 在 `on_main_thread_event` 解码的同一 N-API callback 内把它转成 native 指针；对象
引用不得跨线程保留。该插件没有出站 action。

入站事件 sink 在 `NativeAbility.onCreate` 中 `module.init` 之后立即 attach（`attachBridgeEventSink`），
不依赖 UI 渲染；因此只依赖 `ability` 的插件可以在 `ability-create` 就推送事件，无需等到
`ui-context-ready`。`DefaultXComponent.aboutToAppear` 中的 attach 保留为同一 module 对象的幂等
兜底。

`permission` 的结果顺序和失败码 `-1`、`window` 的四个避让区、`app-control` 的主线程同步退出、
WebView 的 controller ID 与命名 slot 都是既有语义，迁移为插件后不得丢失。

## 4. 执行模式由 trait 限制

`BridgePlugin::Mode` 是封闭 trait 的关联类型，不是可随意切换的配置。它把不正确的线程调用变成
编译期不可表达或运行时立即报错的情况。

| 模式 | Rust 标记与入口 | ArkTS 实现 | 适用场景 | 禁止事项 |
| --- | --- | --- | --- | --- |
| 异步 | `type Mode = AsyncBridge`；`BridgeClient::call_async` / `BridgeRuntime::call_async` | `AsyncBridgePlugin.invokeAsync` | 登录、权限、网络、WebView 控制器、等待生命周期或节点 | 保存 `Env`、`napi_value`、ArkTS object、`UIContext` 或 `FrameNode` 到 worker |
| 主线程同步 | `type Mode = MainThreadSyncBridge`；主线程在导出的 N-API callback 持有 `Env` 时经 `with_main_thread_bridge(...).call_sync`；Rust worker 经 `BridgeRuntime::call_sync_from_worker`（TSFN，执行仍在主线程） | `MainThreadSyncBridgePlugin.invokeSync` | 需要立即返回的平台决定，例如退出、同步窗口查询、同步拦截决策 | `await`、返回 Promise、阻塞等待、投递后再取结果；worker 不能直接用 `call_sync`（无 `Env`），必须走 `call_sync_from_worker` TSFN 通道，且该通道不能从 N-API 主线程调用（会死锁） |

异步 facade 可被 Rust worker 调用，但它传入和拿回的必须都是 `Send + 'static` 的 Rust 所有权数据：

```rust
let response = app.bridge()?
    .call_async::<LoginBridgePlugin, LoginRequest, LoginResponse>(
        "login",
        LoginRequest { account_id },
        BridgeCallOptions::default(),
    )
    .await?;
```

同步 plugin 的 `BridgeMainThread<'env>` 是 `!Send + !Sync`、不可 clone，生命周期仅限当前活跃
N-API callback。业务 facade 必须把 `Env` 作为显式参数接收，而不是缓存它：

```rust
pub trait AppControlExt {
    fn terminate(&self, env: &napi_ohos::Env, code: i32) -> napi_ohos::Result<()>;
}

// 在 #[napi] 导出的回调内调用：
app.with_main_thread_bridge(env, |bridge| {
    bridge.call_sync::<AppControlBridgePlugin, TerminateRequest, TerminateResponse>(
        "terminate",
        TerminateRequest { code: 0 },
    )
})?;
```

#### 4.1 子线程同步调用（TSFN）

同一 `MainThreadSyncBridge` 插件还可在 **Rust worker** 中调用，执行仍发生在 ArkTS 主线程。子线程
没有 `Env`，无法直接触碰 `bridgeInvokeSync` 的函数引用，唯一正确路径是 TSFN：worker 把具名
request 投递到主线程，主线程调用同步插件并解码具名 response，再经 oneshot 把 Rust 所有权数据
送回 worker：

```rust
// 必须从 Rust worker 线程调用；N-API 主线程会死锁，框架会立即报错拒绝。
let response = bridge
    .call_sync_from_worker::<AppControlBridgePlugin, TerminateRequest, TerminateResponse>(
        "terminate",
        TerminateRequest { code: 0 },
    )
    .await?;
```

约束：

- 只能从 worker 调用；从 N-API 主线程调用 `call_sync_from_worker` 会立即返回错误（await 自己的
  TSFN 队列会死锁）。
- 同步插件仍在 ArkTS 主线程同步执行，必须立即返回，不能反过来等待调用方 worker。
- request/response 必须是 `Send + 'static` 的 Rust 所有权数据；编码与解码都在主线程 callback 内
  完成，worker 只收到解码后的具名 response，不接触任何 N-API/ArkTS 对象。
- 该通道复用 `bridgeInvokeSync` 线格式，ArkTS 侧无感知；与主线程 `call_sync` 使用同一份
  ID/version/action/typeName 契约。

ArkTS 平台回调进入 Rust 的 `on_main_thread_event` 是**入站 scoped callback**，不是第三种
执行模式。它也必须在当前 N-API callback 内完成；如果需要做耗时工作，只能先复制已解码的 Rust
所有权数据给 worker，并立即返回本次回调的响应。

## 5. 生命周期与 context

平台对象只保留在 ArkTS。Rust 只能收到受控 lifecycle event 和当前 callback 内的具名 N-API value，
绝不能长期保存 `UIAbilityContext`、`WindowStage`、`UIContext`、`WebviewController` 或 ArkUI node。

插件必须在 Rust 和 ArkTS 两端声明相同的 `REQUIRED_CONTEXTS` / `requires`：

| requirement | 就绪时点 | 适合的能力 |
| --- | --- | --- |
| `ability` | `NativeAbility.onCreate` 已建立 Ability context | 权限、应用控制、登录会话 |
| `window-stage` | `NativeAbility.onWindowStageCreate` | 窗口与避让区 |
| `ui-context` | `DefaultXComponent.aboutToAppear` 已建立 UI context；业务 `BridgeNodeHost` 仅负责附加命名 slot | WebView、任意 ArkUI/FrameNode 插件 |

`BridgeHost` 只会在 requirements 都就绪后调用 `onInstall`，并向延迟激活的插件重放有限的生命周期
历史。插件如需监听销毁、配置或内存事件，应在 ArkTS `onLifecycle` 或 Rust
`BridgePlugin::on_lifecycle` 中处理，而不是替代或绕开 `NativeAbility` 原有生命周期链。

生命周期的调用顺序必须保留为下列链路；插件只能订阅它，不能把原 native module 的 lifecycle
callback 替换掉：

1. `NativeAbility.onCreate` 打开 module/session 对应的 `BridgeHost`，创建 factory，并发出
   `ability-create`。
2. `NativeAbility.onWindowStageCreate` 先提供 `WindowStage`，再发出 `window-stage-create`；窗口事件
   仍要同时转发给原 native module lifecycle。
3. `DefaultXComponent.aboutToAppear` 先挂接 native event sink 和默认节点 slot，再通知 Rust
   `ui-context-ready` 并设置 `UIContext`。这样 plugin `onInstall` 期间已经可以安全发起 scoped
   回调或挂载默认节点。
4. UI 消失时，先发出 `ui-context-destroy`，再 detach slot 和 event sink；WindowStage 销毁时再发出
   `window-stage-destroy`；Ability 销毁时发出 `ability-destroy` 并 dispose 整个 session。
5. `configuration-updated`、`memory-level`、window-stage event 等保持由 `NativeAbility` 原有链路
   分发，同时作为受控 lifecycle event 交给已安装插件。

ArkTS context 是 module + session 范围的。插件不得假设多个 module 共用一个 controller、slot 或
状态表；所有跨页面状态键必须至少包含 `sessionId` 与 `moduleName`。

规则如下：

- 异步调用可以等待 context 就绪；等待必须受 `BridgeCallContext.onCancel` 约束。调用超时或
  Ability/session 销毁时，Host 会取消调用；插件在 `ui-context-destroy` / `window-stage-destroy`
  时必须通过 lifecycle 释放关联资源，并让后续结果或 mount 失败可见。
- 同步调用不能等待。context 未就绪、插件尚未安装或节点未挂载时必须立即报错，由调用方在后续主线程
  callback 重试。
- `onDispose` 必须幂等，负责移除平台 delegate、取消订阅、卸载节点、清空 controller/tag 映射。
  单个插件释放失败不能阻断其余插件释放。
- 禁止用 `setTimeout`、轮询或固定延迟猜测页面、controller 或 context 是否已经就绪。等待条件必须由
  生命周期、attach 事件或真正的平台完成事件驱动。

下面是取消感知等待的标准形态。`onCancel` 返回的取消订阅必须在 resolve、reject 和 cleanup 任一路径
解除，避免页面销毁后留下 waiter：

```ts
const slot = await BridgeNodeSlotRegistry.waitFor(
  context.sessionId,
  context.moduleName,
  slotId,
  context.onCancel,
);
if (!context.isActive()) {
  throw new Error("Bridge call was cancelled before node mount");
}
slot.mount("account.login.surface", node, () => node.dispose());
```

## 6. ArkUI 节点与插槽

需要渲染原生内容的插件（WebView、地图、相机、视频、渲染根节点等）必须通过通用
`BridgeNodeSlot` 挂载自己的 `FrameNode`，不能把具体能力写进 `DefaultXComponent`。

一个 slot 的唯一键是 `(sessionId, moduleName, slotId)`。它的生命周期只有：`attach` → `active` →
`detach/dispose`。异步 waiter 的终态也只有三种：slot attach 后 resolve、桥接调用取消后 reject、
Ability/session 销毁后 reject；不存在“页面 3 秒内未渲染即失败”之类的独立计时器。

- `DefaultXComponent` 固定提供默认 slot `xcomponent-overlay`，并保留既有 Stack、尺寸和透明
  hit-test 行为。
- 业务需要决定位置、层级或混合内容时，应在页面显式放置 `BridgeNodeHost`，使用
  `moduleName + slotId` 指定命名 slot；业务拥有 underlay/foreground/layout，插件只拥有中性
  `NodeContainer` 中自己的节点。
- 同步插件只能使用 `BridgeNodeSlotRegistry.require(...)`，拿不到 slot 立即失败；异步插件使用
  `waitFor(sessionId, moduleName, slotId, context.onCancel)` 等待 attach 或取消。
- mount key 必须以插件 ID 为前缀且在插件内唯一。插件只能卸载自己的 key，并在 `onDispose`、节点
  detach 或创建中途取消时执行 cleanup。
- slot 返回后仍可能在 mount 前失效；插件必须让 `mount` 的 active 校验失败可见，不能在已销毁的
  `NodeController` 上重建节点。

业务页面应按自己的布局显式放置 `BridgeNodeHost`。下面的 `underlay` 与 `foreground` 始终属于业务，
插件拿到的只是中间中性的 `NodeContainer`：

```ts
Stack() {
  DefaultXComponent({ moduleName: "demo_native" })
  BridgeNodeHost({
    moduleName: "demo_native",
    slotId: "webview-panel",
    underlay: this.BusinessUnderlay,
    foreground: this.BusinessForeground,
  })
}
```

这套规则同时保留 WebView 与 XComponent 的混合接入，并允许任意插件接入其他 node 节点；没有
WebView 专用插槽或对业务布局的隐式所有权。

## 7. 平台回调与 WebView 特例

平台回调若需要 Rust 立即决策，ArkTS 必须调用：

```ts
context.invokeNativeSync(event, requestTypeName, responseTypeName, value)
```

Rust 在 `BridgePlugin::on_main_thread_event` 中按事件名和具名 request/response 类型处理。回调不能
持有 ArkTS Function/ObjectRef，也不能异步地再返回本次平台决定。每个可拦截事件必须记录失败语义：
例如导航拦截通常 fail-open，下载准入通常 fail-closed；通知型事件失败只记录并继续平台流程。

所有 synchronous platform callback 均应按以下方式实现：ArkTS 立即解码平台参数为具名 request，调用
`invokeNativeSync`，验证具名 response 后在同一回调栈中返回给平台；Rust 则在
`on_main_thread_event` 中立即给出响应。事件 handler 可把已解码的 Rust owned data 投递给 worker
做记录或后处理，但不得把本次响应留给 worker 决定。

WebView 插件还必须遵守：

- 自定义 scheme 通过 `WebviewProtocol::register` 在 Web engine 初始化前声明；初始化后不允许
  再新增 scheme。
- tag 对应的自定义 protocol、JavaScript proxy 和回调订阅应在 `create` 前声明。controller attach 后，
  必须先安装 delegate/protocol/proxy，再启动首次导航。
- 自定义 protocol 处理 URL 请求；页面 JS proxy 处理 `window.<object>.<method>()` 调用，两者不能
  混为同一种桥。
- 创建时的样式语义（包括 transparent）必须在 `create` action 里完整表达，不能要求业务在创建后
  补一次调用才能得到旧 helper 的效果。
- WebView 的导航、下载开始/结束、标题、controller attach/remove 都是具名 N-API 的同步入站事件；
  出站的 create、evaluate script、load URL 等仍为异步 action。

### 7.1 WebView 回调契约与失败策略

WebView 的 callback builder 必须在 `WebviewClient::create` 前按 webview tag 声明。Rust 保存的是
`Send + Sync + 'static` closure，而不是 ArkTS 函数；ArkTS 在创建时只拿到订阅快照，以决定是否安装
对应 ArkWeb delegate。

| ArkWeb 时点 | Rust 事件/契约 | 默认或错误语义 |
| --- | --- | --- |
| engine 初始化前/后 | `EngineLifecycleEvent` → `EventAcknowledgement` | 初始化前 flush scheme，初始化后封存 scheme 声明 |
| controller attach/remove | `ControllerEvent` → `EventAcknowledgement` | attach 时安装 proxy/protocol，remove 时清理状态 |
| `onLoadIntercept` | `NavigationRequest` → `NavigationResponse` | 未订阅或 handler 失败时 `intercept = false`，fail-open |
| `WebDownloadDelegate.onBeforeDownload` | `DownloadStartRequest` → `DownloadStartResponse` | 失败时取消下载，fail-closed；允许改写临时保存路径 |
| `onDownloadFinish` / `onDownloadFailed` | `DownloadEndEvent` → `EventAcknowledgement` | 含 success 与可选 temp path；通知失败只记录 |
| `onTitleReceive` | `TitleChangeEvent` → `EventAcknowledgement` | 通知失败只记录 |

`transparent` 是 create 时的行为：当 `.transparent(true)` 且未显式指定 background color 时，ArkTS
必须在创建根节点时使用透明色 `#00000000`；显式 background color 优先。不能把这一语义退化为
“创建后业务再调用一次 set-background-color”。

### 7.2 自定义 protocol 与页面 JavaScript

自定义 scheme 与页面 JavaScript bridge 是两项不同能力：前者处理 URL 请求，后者处理
`window.<object>.<method>()` 调用，不能混用同一个 handler 或生命周期。

1. 应用在 `#[ability]` 初始化期间通过 `WebviewProtocol::register` 声明 scheme 及 option；该步骤
   必须早于 `WebviewController.initializeWebEngine()`。
2. ArkTS `WebviewPlugin.onInstall` 发出 `before-engine-init`；Rust flush 全部 scheme 声明后，ArkTS
   才初始化 engine，并以 `engine-initialized` 封存声明集。封存后新增 scheme 必须确定性失败。
3. 业务在 `WebviewClient::create` 前按 tag 调用 `custom_protocol`、注册 JS proxy 和 callback；Rust
   只保存 tag/scheme/closure 声明，不能保存 ArkTS controller。
4. controller attach 后先通过 scoped direct event 安装 protocol、proxy 与 delegate，再开始首次
   `loadUrl`。若 handler 在 controller 存在后增量注册，应立即绑定；JS proxy 如需重新生效则刷新页面。

主动执行页面脚本使用异步具名 action `ohos.webview.ScriptRequest` →
`ohos.webview.ScriptResponse`，对应 `handle.evaluate_script(...)`。它必须等待 controller attach，
不能用定时器假设 create 返回后 controller 已可执行脚本。

## 8. Helper 迁移、对外 API 与应用装配

旧 helper 不是兼容层，也不是 framework 的长期扩展点。每项有平台语义的 helper 必须迁移为独立插件，
并把原有行为作为插件 facade 的验收基线：

| 原能力 | 目标插件 | 调用限制与保留语义 |
| --- | --- | --- |
| `requestPermission` | `plugin-permission` / `ohos.permission` | async + `ability`；结果顺序与失败码保持不变 |
| `exit` | `plugin-app-control` / `ohos.app-control` | sync + 当前主线程 `Env` |
| `getWindowAvoidArea` | `plugin-window` / `ohos.window` | sync + `window-stage`；返回完整避让区 |
| `createWebview`、嵌入式 WebView、custom protocol、导航/下载/标题回调 | `plugin-webview` / `ohos.webview` | 出站 async + `ui-context`；入站为 scoped 主线程具名 N-API；scheme 在 engine 初始化前声明 |
| `Loadable` | `runtime/NativeModuleLoader` | framework 内部 runtime，不是能力 bridge |
| `openURL` | `plugin-url` / `ohos.url` | async + `ability`；`context.openLink` |
| `showFileDialog`（open/save/folder） | `plugin-files` / `ohos.files` | async + `ability`；结构化 `DialogOptions` 传参，filter 字符串语法仅在 ArkTS 插件内部转换 |
| `random`、`objectAssign` 等纯工具函数 | 使用点或插件内部 | 不再作为 framework helper 暴露 |

迁移时应删除 core 中针对该能力的 helper、类型、factory import、宏参数和页面专用字段；禁止保留
“旧 helper 调新插件”的双入口，也禁止以 JSON/弱类型 wrapper 伪造兼容。

Rust crate 应提供业务语义清晰的扩展 trait 或 client，而非要求业务拼接 plugin ID、action 或
`BridgeTypedValue`。例如 `PermissionExt::request_permission`、`WebviewExt::webview`。

Rust facade 必须在 `#[ability]` 初始化器中、UI render 前注册。该注册用于接收 lifecycle 与 ArkTS
直达事件；它与 ArkTS factory 的应用装配缺一不可：

```rust
#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(LoginBridgePlugin)
        .expect("login Rust facade must be registered exactly once");
}
```

ArkTS HAR 导出唯一 factory，应用通过 `NativeAbility.bridgePlugins` 显式装配：

```ts
import { createAppControlPlugin } from "@ohos-rs/plugin-app-control";
import { createLoginPlugin } from "@ohos-rs/plugin-login";
import { createPermissionPlugin } from "@ohos-rs/plugin-permission";
import { createWebviewPlugin } from "@ohos-rs/plugin-webview";
import { createWindowPlugin } from "@ohos-rs/plugin-window";

export default class EntryAbility extends NativeAbility {
  bridgePlugins = [
    createPermissionPlugin(),
    createAppControlPlugin(),
    createWindowPlugin(),
    createWebviewPlugin(),
    createLoginPlugin(),
  ];
}
```

factory 可以用 `modules` 限制适用的 native module。未装配、版本不匹配、模式不匹配和类型不匹配
都应在桥接边界确定性报错，不得悄悄回退到 helper 或 JSON 兼容路径。

`LazyPlugin`（默认）在 `BridgeHost.install` 时为每个 native module 和 Ability session 创建独立
实例；`EagerPlugin` 共享一个调用方构造的实例，用于持有进程级全局状态的插件（例如只做一次
native wrapper 推送的 `ohos.resource`）。共享实例会被重复 `attachContext`，必须容忍重复的
lifecycle 通知与 dispose。

## 9. 实现、Demo 与验收

每个新插件必须提供一个可运行 demo。demo 不是只验证 HAR 能安装，而是要走完 Rust → bridge → ArkTS
→ platform → Rust 的真实路径。至少覆盖下列与插件相关的分支：

| 场景 | 必须验证的结果 |
| --- | --- |
| 异步 action | Rust worker 可以发起调用；ArkTS Promise 完成后 Rust 收到具名 response，不存在 JSON encode/decode |
| 主线程同步 action（如有） | 在 `#[napi]` callback 的 `Env` 内成功；`call_sync` 不能从 worker 直接调用（无 `Env`）；没有 Promise 或阻塞等待 |
| 子线程同步 action（TSFN，如有） | 从 Rust worker 调用 `call_sync_from_worker` 成功拿到具名 response；从 N-API 主线程调用被立即拒绝（防死锁） |
| context 延迟 | async 调用会等待真正的 context/slot attach；sync 调用在未就绪时立即失败 |
| 生命周期销毁 | timeout、Ability/session destroy 会取消调用；UI/WindowStage detach 会触发生命周期 cleanup，临时节点、delegate、waiter 和映射被释放或失效 |
| 原生节点（如有） | 默认 `xcomponent-overlay` 与业务命名 `BridgeNodeHost` 都能挂载，业务 underlay/foreground 行为不变 |
| 平台回调（如有） | 在当前回调栈完成 Rust 决策，并覆盖明确的 fail-open/fail-closed 语义 |
| WebView（如有） | custom scheme、首次导航前安装、透明背景、导航、下载、标题和 JS script/proxy 均覆盖 |

建议在 demo 中同时保留三个最小参考能力：异步登录、主线程同步调用、以及 `String`、`Vec<u8>`、
`#[napi(object)]` 三种具名 N-API 值的 raw transport。这样新插件可以直接验证类型边界而非依赖 JSON。

新增或迁移插件必须完成以下项目后才可合入：

- [ ] 建立 `crates/plugin-<name>` 与 `plugins/<name>` 成对包，并完成 workspace/HAR/应用装配登记。
- [ ] Rust `BridgePlugin` 与 ArkTS factory 的 ID、VERSION、Mode、requires 完全一致。
- [ ] 每个 request/response 都是具名 N-API 类型；ArkTS 输入校验 `typeName` 和字段，输出填写
  正确的 `typeName`；不存在 JSON 桥接代码。
- [ ] 同步 facade 支持主线程 `Env` 调用与（如提供）worker `call_sync_from_worker` 两条路径，两条
  路径都不保存任何 N-API/ArkTS 对象；异步 facade 和 callback 不保存任何 N-API/ArkTS 对象。
- [ ] 需要生命周期或 context 的插件声明 requirements，覆盖 delayed activation、destroy、dispose
  和调用取消；没有 timer 轮询。
- [ ] 需要 UI 的插件通过 `BridgeNodeSlot` 接入，覆盖默认 XComponent slot、业务命名 slot、detach
  和中途取消 cleanup；未改坏默认 XComponent 的既有行为。
- [ ] 平台回调通过 `invokeNativeSync` + `on_main_thread_event`，明确同步时限和失败策略。
- [ ] WebView（如涉及）覆盖 engine 初始化、custom protocol、首次导航、delegate 安装、透明背景和
  所有已支持回调。
- [ ] Rust 单测至少覆盖 typeName、参数校验、业务结果校验和 mode/context 声明；ArkTS/demo 覆盖 async、
  sync-main-thread、生命周期延迟和销毁取消路径。
- [ ] 运行仓库规定的 Rust、ArkTS 格式化、编译与测试检查；评审中检索 JSON 桥接关键词，确认没有新增。

至少执行以下检查（以仓库实际脚本和目标包名替换尖括号内容）：

```bash
cargo check --workspace
cargo test -p openharmony-ability-plugin-<name> --lib
cargo clippy --workspace --all-targets -- -D warnings
pnpm run format:check
rg -n "BridgeJson|call_json|bridgeJson|requireBridgeJson|JSON\\.stringify|JSON\\.parse" \
  crates/plugin-<name> plugins/<name> native_ability
```

ArkTS/HAP 编译和真机验证也属于合入条件；仅 Rust 单测通过不能证明 N-API typeName、主线程 scope
或 ArkUI 生命周期正确。

## 10. 推荐评审问题

1. core 是否仍然不知道该插件的具体能力、平台类型和业务语义？
2. Rust 与 ArkTS 是否对 ID、版本、模式、context、action 和 typeName 使用同一份契约？
3. 是否能证明同步路径不会 `await`，异步路径不会保存 Env/ArkTS 对象？
4. 插件依赖的生命周期、slot attach、取消和 dispose 是否都有明确的事件驱动路径？
5. 若插件为 WebView 或其他原生节点，业务是否仍拥有布局和内容插槽？
6. request/response 与反向平台回调是否完全没有 JSON transport？
