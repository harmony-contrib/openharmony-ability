# 内置插件具名 N-API 契约表

来源：`docs/plugin-development-standard.md` §3 与各插件源码。新增/修改 action 时必须与本表
保持命名一致（typeName 两端一字不差）。

## 通用约定

- 调用载荷不是 JSON envelope，而是 `{ typeName, value }` 的 `BridgeTypedValue`。
- `#[napi(object)]` 的 snake_case 字段按 N-API 规则映射为 ArkTS camelCase 字段。
- ArkTS → Rust 的反向事件使用 `context.invokeNativeSync(event, requestTypeName,
  responseTypeName, value)`，同样传递具名 N-API value，不使用 JSON event port。
- 内置标量类型：`std.string`、`std.bytes`、`std.bool`、`std.i32`、`std.f64`。
- C++ N-API 插件必须使用相同的 `(pluginId, action, requestTypeName,
  responseTypeName, value)` 边界，不得跨 worker 保存 `napi_env`/`napi_ref`/ArkTS 对象。

## 契约总表

| 插件 / action | request type → ArkTS value | response type → ArkTS value | 模式 / context |
|---|---|---|---|
| `ohos.app-control` / `terminate` | `ohos.app_control.TerminateRequest` → `{ code }` | `ohos.app_control.TerminateResponse` → `{ accepted }` | sync / `ability` |
| `ohos.permission` / `request` | `ohos.permission.PermissionRequest` → `{ permissions }` | `ohos.permission.PermissionResponse` → `{ codes }` | async / `ability` |
| `ohos.window` / `get-avoid-area` | `ohos.window.AvoidAreaRequest` → `{ areaType }` | `ohos.window.AvoidAreaResponse` → `{ area: { visible, leftRect, topRect, rightRect, bottomRect } }` | async / `ui-context`；查询当前 component 所在窗口 |
| `ohos.window` / `create-os-window`、`set-decorations`、`set-background-color`、`set-blur`、`focus`、`set-focusable`、`move-to`、`resize`、`minimize`、`maximize`、`restore`、`recover`、`show`、`destroy-window`、`is-maximized`、`is-minimized` | `ohos.window.CreateRequest` / `WindowIdRequest` / `DecorationsRequest` / `ColorRequest` / `BlurRequest` / `MoveRequest` / `ResizeRequest` / `FocusableRequest` | `ohos.window.CreateResponse` → `{ windowId }` / `Acknowledgement` → `{ accepted }` / `StateResponse` → `{ value }` | async / `ui-context` |
| `ohos.webview` / `create` | `ohos.webview.CreateRequest` → `{ id, parentHandle?, ... }` | `ohos.webview.CreateResponse` → `{ id }` | async / `ui-context` |
| `ohos.webview` / `set-visible`、`set-background-color`、`remove`、`load-url`、`load-html`、`set-zoom`、`reload`、`focus`、`clear-all-browsing-data` | `ohos.webview.ControllerRequest` → `{ id, visible?, color?, url?, html?, headers?, zoom? }` | `ohos.webview.Acknowledgement` → `{ accepted }` | async / `ui-context` |
| `ohos.webview` / `get-url`、`cookies-with-url` | `ohos.webview.ControllerRequest` → `{ id, url? }` | `ohos.webview.StringResponse` → `{ value }` | async / `ui-context` |
| `ohos.webview` / `evaluate-script` | `ohos.webview.ScriptRequest` → `{ id, script }` | `ohos.webview.ScriptResponse` → `{ result }` | async / `ui-context` |
| `ohos.resource` / `resource-manager-ready`（入站） | `ohos.resource.ResourceManagerRef`（ArkTS 直接传 `resourceManager` 对象） | `ohos.resource.ResourceManagerReadyResponse` → `{ accepted }` | 入站事件 / `ability` |

## 代码位置

| 插件 | Rust facade | ArkTS 实现 |
|---|---|---|
| permission | `crates/plugin-permission/src/lib.rs` | `plugins/permission/src/main/ets/PermissionPlugin.ets` |
| app-control | `crates/plugin-app-control/src/lib.rs` | `plugins/app-control/src/main/ets/AppControlPlugin.ets` |
| window | `crates/plugin-window/src/lib.rs` | `plugins/window/src/main/ets/WindowPlugin.ets` |
| webview | `crates/plugin-webview/src/lib.rs` | `plugins/webview/src/main/ets/WebviewPlugin.ets` |
| resource | `crates/plugin-resource/src/lib.rs` | `plugins/resource/src/main/ets/ResourcePlugin.ets` |
| webview 自定义协议 | `crates/plugin-webview/src/protocol.rs` | —（纯 native，ArkTS 只触发 `before-engine-init`/`engine-initialized` 事件） |
| webview JS proxy | `crates/plugin-webview/src/js_proxy.rs` | —（纯 native，依赖 `controller-attached` 事件） |

## WebView 反向事件（具名 N-API 类型）

| 事件 | request type → response type | 方向 |
|---|---|---|
| `seal-engine-schemes` / `before-engine-init` / `engine-initialized` | `ohos.webview.EngineLifecycleEvent` → `ohos.webview.EngineLifecycleResponse` | ArkTS → Rust |
| `controller-attached` / `controller-removed` | `ohos.webview.ControllerEvent` → `ohos.webview.EventAcknowledgement` | ArkTS → Rust |
| `navigation-request` | `ohos.webview.NavigationRequest` → `ohos.webview.NavigationResponse` | ArkTS → Rust |
| `download-start` | `ohos.webview.DownloadStartRequest` → `ohos.webview.DownloadStartResponse` | ArkTS → Rust |
| `download-end` | `ohos.webview.DownloadEndEvent` → `ohos.webview.EventAcknowledgement` | ArkTS → Rust |
| `title-change` | `ohos.webview.TitleChangeEvent` → `ohos.webview.EventAcknowledgement` | ArkTS → Rust |

## WebView 规则

下载、导航与标题回调已经使用上述具名 N-API 契约实现。新增 WebView callback 时必须在
`docs/plugin-development-standard.md` §7.1 记录 request/response 与失败策略，且不得回退到 JSON。
