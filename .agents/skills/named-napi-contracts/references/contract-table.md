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
| `ohos.window` / `set-custom-cursor` | `ohos.window.CustomCursorRequest` → `{ windowId, rgba, width, height, hotspotX, hotspotY }` | `ohos.window.Acknowledgement` → `{ accepted }` | async / `ui-context`；静态 RGBA 光标及热点 |
| `ohos.window` / `set-window-icon` | `ohos.window.WindowIconRequest` → `{ windowId, rgba, size }` | `ohos.window.Acknowledgement` → `{ accepted }` | async / `ui-context`；API 22+ PC/2in1 主窗口；size=0 恢复打包图标 |
| `ohos.window` / `create-os-window`、`set-decorations`、`set-background-color`、`set-blur`、`focus`、`set-focusable`、`move-to`、`resize`、`minimize`、`maximize`、`restore`、`recover`、`show`、`destroy-window`、`is-maximized`、`is-minimized` | `ohos.window.CreateRequest` / `WindowIdRequest` / `DecorationsRequest` / `ColorRequest` / `BlurRequest` / `MoveRequest` / `ResizeRequest` / `FocusableRequest` | `ohos.window.CreateResponse` → `{ windowId }` / `Acknowledgement` → `{ accepted }` / `StateResponse` → `{ value }` | async / `ui-context` |
| `ohos.webview` / `create` | `ohos.webview.CreateRequest` → `{ id, parentHandle?, incognito?, nativeKeyboard?, ... }` | `ohos.webview.CreateResponse` → `{ id }` | async / `ui-context`（`nativeKeyboard: true` 跳过 MainPage 合成键 shim） |
| `ohos.webview` / `set-pointer-events` | `ohos.webview.PointerEventsRequest { id, enabled }` | `ohos.webview.Acknowledgement` | async / `ui-context` |
| `ohos.webview` / `pointer-down` | `ohos.webview.PointerEvent { id, nativeTag, x, y, button, modifiers }` | `ohos.webview.EventAcknowledgement` | scoped reverse event; component-local vp, buttons 0–4, Shift=1/Ctrl=2/Alt=4 |
| `ohos.webview` / `set-visible`、`set-background-color`、`remove`、`load-url`、`load-html`、`set-zoom`、`reload`、`reload-ignore-cache`、`focus`、`clear-all-browsing-data` | `ohos.webview.ControllerRequest` → `{ id, visible?, color?, url?, html?, headers?, zoom? }` | `ohos.webview.Acknowledgement` → `{ accepted }` | async / `ui-context` |
| `ohos.webview` / `get-url`、`cookies-with-url` | `ohos.webview.ControllerRequest` → `{ id, url? }` | `ohos.webview.StringResponse` → `{ value }` | async / `ui-context` |
| `ohos.webview` / `evaluate-script`、`evaluate-async-script` | `ohos.webview.ScriptRequest` → `{ id, script, timeoutMs? }` | `ohos.webview.ScriptResponse` / `ohos.webview.AsyncScriptResponse` | async / `ui-context`（异步脚本基于 JS Proxy 事件回调） |
| `ohos.webview` / `serialize-state`、`restore-state`、`set-audio-muted` | `ControllerRequest` / `RestoreStateRequest` / `AudioMutedRequest` | `StateResponse` / `BooleanResponse` / `Acknowledgement` | async / `ui-context` |
| `ohos.webview` / `resolve-download`、`resolve-permission-request`、`resolve-http-auth`、`resolve-ssl-error` | `ResolveDownloadRequest` / `ResolvePermissionRequest` / `ResolveHttpAuthRequest` / `ResolveSslErrorRequest` | `ohos.webview.Acknowledgement` | async / `ui-context` |
| `ohos.resource` / `resource-manager-ready`（入站） | `ohos.resource.ResourceManagerRef`（ArkTS 直接传 `resourceManager` 对象） | `ohos.resource.ResourceManagerReadyResponse` → `{ accepted }` | 入站事件 / `ability` |
| `ohos.audio` / `update` | `ohos.audio.UpdateRequest` → `{ player, sourceFd?, replace, release, play, volume, reportErrors, label }` | `ohos.audio.UpdateResponse` → `{ accepted }` | async / `ability` |

## 2026-11 Viva / MyGo 主线增补

| 插件 / action | request type | response type | 语义与边界 |
|---|---|---|---|
| `ohos.webview` / `set-viewport` | `ohos.webview.ViewportRequest` | `ohos.webview.Acknowledgement` | frame 为窗口 vp，clip/inputRegions 为视口内 vp；最多 256 输入区域，空数组禁止命中；保留旧 set-bounds 语义 |
| `ohos.webview` / `cookies-details` | `ohos.webview.ControllerRequest` | `ohos.webview.CookiesResponse` | API 23+ 全部 Cookie，保留 domain/path/secure/httpOnly/sameSite/到期 Unix 毫秒 |
| `ohos.webview` / `clear-cookies` | `ohos.webview.ControllerRequest` | `ohos.webview.Acknowledgement` | 仅清理 Cookie；不删除其他浏览数据 |
| `ohos.window` / `show-prompt-choice` | `ohos.window.PromptChoiceRequest` | `ohos.window.PromptChoiceResponse` | 实际窗口中的 ArkUI Checkbox（API 12+）；index 与 checked 一起返回；取消和销毁关闭对话框 |
| `ohos.window` / `set-privacy-mode` | `ohos.window.PrivacyRequest` | `ohos.window.Acknowledgement` | 设置窗口防截屏/隐私模式 |
| `ohos.window` / `set-shadow` | `ohos.window.ShadowRequest` | `ohos.window.Acknowledgement` | 主窗口尝试 API 20+ `setWindowShadowEnabled`；子窗口尝试 API 17+ `setWindowShadowRadius`；不支持或无权限返回 `accepted: false` |
| `ohos.window` / `get-title-button-rect` | `ohos.window.WindowIdRequest` | `ohos.window.TitleButtonRectResponse` | 返回 `{ available, right, top, width, height }`（单位 vp，`right` 为距窗口右边距） |
| `ohos.window` / `set-input-region` | `ohos.window.InputRegionRequest` | `ohos.window.Acknowledgement` | 物理像素 `px`；空数组置 `setWindowTouchable(false)`；API 26+ 有权限时优先 `setTouchableAreas`，否则 `px2vp` 降级至根 FrameNode `responseRegion`/`mouseResponseRegion` |
| `ohos.files` / `trash-item` | `ohos.files.TrashItemRequest` | `ohos.files.TrashItemResponse` | 将文件/目录移入回收站（支持 `file://` 与沙箱路径） |
| `ohos.files` / `get-file-icon` | `ohos.files.FileIconRequest` | `ohos.files.FileIconResponse` | 获取文件/UTD 图标 PNG（需 `ohos.permission.GET_FILE_ICON` 时有效；离屏快照 + 64 条 LRU 缓存） |
| `ohos.notification` / `show` | `ohos.notification.ShowRequest` | `ohos.notification.Acknowledgement` | 统一通知入口：支持可选 `silent`（API 23+）、`group`、`senderName`、`image`（等比限边 512px）、`avatar`、`slot`（`"default" \| "social"`） |
| `ohos.notification` / `parse-response` | `ohos.notification.ResponseRequest` | `ohos.notification.Response` | 仅识别配置 scheme 的 response URI，包含 matched/tag/action；普通深链不匹配 |
| `ohos.notification` / `dismiss-all` | `ohos.notification.EmptyRequest` | `ohos.notification.Acknowledgement` | 撤销本应用通知，包含以前启动发布的通知 |
| `ohos.system-state` / `prevent-sleep`、`release-sleep` | `PreventSleepRequest` / `ReleaseSleepRequest` | `PreventSleepResponse` / `ReleaseSleepResponse` | API 23+ `BACKGROUND_USER_IDLE` 运行锁，需 `ohos.permission.RUNNING_LOCK` |
| `ohos.system-state` / `request-suspend-delay`、`cancel-suspend-delay` | `SuspendDelayRequest` / `CancelSuspendDelayRequest` | `SuspendDelayResponse` / `CancelSuspendDelayResponse` | 后台短时任务；超时回调自动 `cancelSuspendDelay` 并发送 `suspend-delay-expired` |
| `ohos.system-state` / `get-locale-region`、`set-app-preferred-language`、`get-package-info`、`get-network-status`、`get-power-status`、`set-now-playing` | 对应具名 Request | 对应具名 Response | 系统区域/语言/应用信息/网络/电源（`isBatteryPresent`）/媒体控制位掩码 |

所有新 action 均为 async；WebView 和窗口需要 ui-context，通知需要 ability。不新增全局回调缓存。

## 代码位置

| 插件 | Rust facade | ArkTS 实现 |
|---|---|---|
| permission | `crates/plugin-permission/src/lib.rs` | `plugins/permission/src/main/ets/PermissionPlugin.ets` |
| app-control | `crates/plugin-app-control/src/lib.rs` | `plugins/app-control/src/main/ets/AppControlPlugin.ets` |
| window | `crates/plugin-window/src/lib.rs` | `plugins/window/src/main/ets/WindowPlugin.ets` |
| webview | `crates/plugin-webview/src/lib.rs` | `plugins/webview/src/main/ets/WebviewPlugin.ets` |
| resource | `crates/plugin-resource/src/lib.rs` | `plugins/resource/src/main/ets/ResourcePlugin.ets` |
| audio | `crates/plugin-audio/src/lib.rs` | `plugins/audio/src/main/ets/AudioPlugin.ets` |
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
| `native-key-event` | `ohos.webview.NativeKeyEvent { id, nativeTag, targetId, ... }` → `ohos.webview.EventAcknowledgement` | ArkTS → Rust |
| `load-error` / `audio-state-changed` / `window-exit` / `render-exited` / `permission-request` / `http-auth-request` / `ssl-error` | 对应具名 Event（均携带 `id` 与 `nativeTag`）→ `ohos.webview.EventAcknowledgement` | ArkTS → Rust |

## WebView 规则

下载、导航与标题回调已经使用上述具名 N-API 契约实现。新增 WebView callback 时必须在
`docs/plugin-development-standard.md` §7.1 记录 request/response 与失败策略，且不得回退到 JSON。
