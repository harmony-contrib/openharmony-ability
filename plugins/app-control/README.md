# @ohos-rs/ability-plugin-app-control

这是应用进程控制的 ArkTS HAR，对应 Rust crate
`openharmony-ability-plugin-app-control`。它实现主线程同步的 `terminate` action，并通过
`@ohos.process` 的 `ProcessManager.exit(code)` 结束应用进程。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-app-control
```

## 装配

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.0",
    "@ohos-rs/ability-plugin-app-control": "1.0.0-beta.0"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AppControlPlugin } from "@ohos-rs/ability-plugin-app-control";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AppControlPlugin())];
}
```

Rust 必须同时注册 `AppControlBridgePlugin`，并只在当前 N-API callback 的 `Env` 中调用
`AppControlExt::terminate`。完整 Rust 用法见
[Rust facade README](../../crates/plugin-app-control/README.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.app-control` |
| `execution` | `sync-main-thread` |
| `requires` | `["ability"]` |
| 支持 action | `terminate` |
| request → response | `ohos.app_control.TerminateRequest { code }` → `ohos.app_control.TerminateResponse { accepted }` |

该 plugin 的 `invokeSync` 不能返回 Promise、不能 `await`，也不能等待 context。Host 在 Ability 未就绪、
plugin 未安装或调用方走错异步入口时立即报错。

## 行为与安全边界

- `code` 必须是整数；类型或 action 不匹配直接抛错。
- 成功调用 `ProcessManager.exit(code)` 后，调用方不得假设后续 UI 或 Rust 逻辑仍会运行。
- 该 HAR 不提供业务层的“确认退出” UI；确认、保存状态和风险提示必须由业务在调用 Rust facade 前完成。
- request/response 是具名 N-API object，禁止 JSON transport。

更多主线程同步约束与验收标准见
[插件开发规范](../../docs/plugin-development-standard.md)。
