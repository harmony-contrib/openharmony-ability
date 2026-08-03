# 内置插件具名 N-API 契约表

来源：`docs/plugin-development-standard.md` §3 与各插件源码。新增/修改 action 时必须与本表
保持命名一致（typeName 两端一字不差）。

## 通用约定

- 调用载荷不是 JSON envelope，而是 `{ typeName, value }` 的 `BridgeTypedValue`。
- `#[napi(object)]` 的 snake_case 字段按 N-API 规则映射为 ArkTS camelCase 字段。
- ArkTS → Rust 的反向事件使用 `context.invokeNativeSync(event, requestTypeName,
  responseTypeName, value)`，同样传递具名 N-API value，不使用 JSON event port。
- 内置标量类型：`std.string`、`std.bytes`、`std.bool`、`std.i32`、`std.f64`。
- C++ N-API 插件必须使用相同的 `(pluginId, version, action, requestTypeName,
  responseTypeName, value)` 边界，不得跨 worker 保存 `napi_env`/`napi_ref`/ArkTS 对象。

## 契约总表

| 插件 / action | request type → ArkTS value | response type → ArkTS value | 模式 / context |
|---|---|---|---|
| `ohos.app-control` / `terminate`、`restart`、`set-color-mode` | `ohos.app_control.TerminateRequest`/`RestartRequest`/`ColorModeRequest` | `ohos.app_control.TerminateResponse`/`RestartResponse`/`ColorModeResponse` → `{ accepted }` | sync / `ability` |
| `ohos.permission` / `request` | `ohos.permission.PermissionRequest` → `{ permissions }` | `ohos.permission.PermissionResponse` → `{ codes }` | async / `ability` |
| `ohos.window` / `get-avoid-area` | `ohos.window.AvoidAreaRequest` → `{ areaType }` | `ohos.window.AvoidAreaResponse` → `{ area: { visible, leftRect, topRect, rightRect, bottomRect } }` | sync / `window-stage` |
| `ohos.window` / `create-os-window`、`set-decorations`、`set-background-color`、`set-blur`、`focus`、`set-focusable`、`move-to`、`resize`、`minimize`、`maximize`、`restore`、`recover`、`show`、`is-maximized`、`is-minimized` | `ohos.window.CreateRequest` / `WindowIdRequest` / `DecorationsRequest` / `ColorRequest` / `BlurRequest` / `MoveRequest` / `ResizeRequest` / `FocusableRequest` | `ohos.window.CreateResponse` → `{ windowId }` / `Acknowledgement` → `{ accepted }` / `StateResponse` → `{ value }` | sync / `window-stage` |
| `ohos.webview` / `create` | `ohos.webview.CreateRequest` → `WebviewCreateRequest` | `ohos.webview.CreateResponse` → `{ id, slotId }` | async / `ui-context` |
| `ohos.webview` / `set-visible`、`set-background-color`、`remove`、`load-url`、`load-html`、`set-zoom`、`reload`、`focus`、`clear-all-browsing-data` | `ohos.webview.ControllerRequest` → `{ id, slotId, visible, color, url, html, headers, zoom }` | `ohos.webview.Acknowledgement` → `{ accepted }` | async / `ui-context` |
| `ohos.webview` / `get-url`、`cookies-with-url` | `ohos.webview.ControllerRequest` → `{ id, slotId, url }` | `ohos.webview.StringResponse` → `{ value }` | async / `ui-context` |
| `ohos.webview` / `evaluate-script` | `ohos.webview.ScriptRequest` → `{ id, slotId, script }` | `ohos.webview.ScriptResponse` → `{ result }` | async / `ui-context` |
| `ohos.webview` / `set-bounds`、`set-cookie`、`snapshot`、`create-pdf`、`set-debugging-access`、`is-debugging-access` | `ohos.webview.BoundsRequest` / `CookieRequest` / `SnapshotRequest` / `PdfRequest`（`PdfConfig`） / `BoolRequest` | `ohos.webview.Acknowledgement` / `SnapshotResponse` → `{ rgba, width, height }` / `BoolResponse` → `{ value }` | async / `ui-context` |
| `ohos.clipboard` / `write-image` | `ohos.clipboard.ImageRequest` → `{ rgba, width, height }` | `ohos.clipboard.Acknowledgement` → `{ accepted }` | async / `ability` |
| `ohos.updater` / `check`、`download-and-install` | `ohos.updater.CheckRequest` | `ohos.updater.CheckResponse` → `{ result }`（`CheckResult`）/ `Acknowledgement` | async / `ability` |
| `ohos.menu` / `set-menubar`、`popup`、`set-menubar-visible` | `ohos.menu.MenuBarRequest` / `PopupRequest` / `VisibilityRequest`（递归 `MenuItemData`） | `ohos.menu.Acknowledgement` → `{ accepted }` | async / `ability` |
| `ohos.menu` / 主线程事件 `menu-click` | `ohos.menu.ClickRequest` → `{ id, windowId }` | `ohos.menu.ClickResponse` → `{ accepted }` | scoped 主线程具名 N-API |
| `ohos.statusbar` / `add`、`remove`、`update-icon`、`update-menu`、`update-tips`、`predefined-action` | `ohos.statusbar.AddRequest`（`ItemData`）/ `IconRequest` / `MenuRequest` / `TipsRequest` / `ActionRequest` | `ohos.statusbar.Acknowledgement` → `{ accepted }` | async / `ability` |
| `ohos.statusbar` / 主线程事件 `icon-click`、`menu-click` | `ohos.statusbar.ClickRequest` → `{ clickType }` / `MenuClickRequest` → `{ menuCode }` | `ohos.statusbar.ClickResponse` → `{ accepted }` | scoped 主线程具名 N-API |
| `ohos.version` / `get-sdk-api-version`、`get-distribution-api-version`、`can-i-use`、`is-desktop-device` | `ohos.version.VersionRequest` → `{ syscap }` | `ohos.version.VersionResponse` → `{ value, result }` | sync / `ability` |

## 代码位置

| 插件 | Rust facade | ArkTS 实现 |
|---|---|---|
| permission | `crates/plugin-permission/src/lib.rs` | `plugins/permission/src/main/ets/PermissionPlugin.ets` |
| app-control | `crates/plugin-app-control/src/lib.rs` | `plugins/app-control/src/main/ets/AppControlPlugin.ets` |
| window | `crates/plugin-window/src/lib.rs` | `plugins/window/src/main/ets/WindowPlugin.ets` |
| webview | `crates/plugin-webview/src/lib.rs` | `plugins/webview/src/main/ets/WebviewPlugin.ets` |
| clipboard | `crates/plugin-clipboard/src/lib.rs` | `plugins/clipboard/src/main/ets/ClipboardPlugin.ets` |
| updater | `crates/plugin-updater/src/lib.rs` | `plugins/updater/src/main/ets/UpdaterPlugin.ets` |
| menu | `crates/plugin-menu/src/lib.rs` | `plugins/menu/src/main/ets/MenuPlugin.ets` |
| statusbar | `crates/plugin-statusbar/src/lib.rs` | `plugins/statusbar/src/main/ets/StatusBarPlugin.ets` |
| version | `crates/plugin-version/src/lib.rs`（core `crates/ability/src/version.rs` 提供 init/getters） | `plugins/version/src/main/ets/VersionPlugin.ets` |
| webview 自定义协议 | `crates/plugin-webview/src/protocol.rs` | —（纯 native，ArkTS 只触发 `before-engine-init`/`engine-initialized` 事件） |
| webview JS proxy | `crates/plugin-webview/src/js_proxy.rs` | —（纯 native，依赖 `controller-attached` 事件） |

## WebView 反向事件（具名 N-API 类型）

| 事件 | request type → response type | 方向 |
|---|---|---|
| `before-engine-init` / `engine-initialized` | `ohos.webview.EngineLifecycleEvent` → `ohos.webview.EventAcknowledgement` | ArkTS → Rust |
| `controller-attached` / `controller-removed` | `ohos.webview.ControllerEvent` → `ohos.webview.EventAcknowledgement` | ArkTS → Rust |
| `navigation-request` | `ohos.webview.NavigationRequest` → `ohos.webview.NavigationResponse` | ArkTS → Rust |
| `download-start` | `ohos.webview.DownloadStartRequest` → `ohos.webview.DownloadStartResponse` | ArkTS → Rust |
| `download-end` | `ohos.webview.DownloadEndEvent` → `ohos.webview.EventAcknowledgement` | ArkTS → Rust |
| `title-change` | `ohos.webview.TitleChangeEvent` → `ohos.webview.EventAcknowledgement` | ArkTS → Rust |

## WebView 规则

下载、导航与标题回调已经使用上述具名 N-API 契约实现。新增 WebView callback 时必须在
`docs/plugin-development-standard.md` §7.1 记录 request/response 与失败策略，且不得回退到 JSON。
