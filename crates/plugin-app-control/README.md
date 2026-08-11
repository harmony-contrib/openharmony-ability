# openharmony-ability-plugin-app-control

`openharmony-ability-plugin-app-control` 提供应用进程控制的 Rust facade。目前公开能力为以指定退出码
结束进程。它与 ArkTS HAR `@ohos-rs/ability-plugin-app-control` 成对使用，并且是严格的主线程同步插件。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-app-control` |
| ArkTS HAR | `@ohos-rs/ability-plugin-app-control` |
| 插件 ID | `ohos.app-control` |
| 执行模式 | 主线程同步：`MainThreadSyncBridge` / `invokeSync` |
| 前置 context | `ability` |
| action | `terminate` |
| request → response | `ohos.app_control.TerminateRequest { code }` → `ohos.app_control.TerminateResponse { accepted }` |

## 接入

Rust facade 和 ArkTS factory 都必须在应用启动期装配：

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_app_control::AppControlBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(AppControlBridgePlugin)
        .expect("app-control facade must be registered once");
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AppControlPlugin } from "@ohos-rs/ability-plugin-app-control";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AppControlPlugin())];
}
```

同时在应用 `oh-package.json5` 添加 `@ohos-rs/ability-plugin-app-control`。HAR 的具体依赖和 plugin 说明见
[ArkTS README](../../plugins/app-control/README.md)。

## Rust 使用方式

`AppControlExt::terminate` 只能在导出的 N-API callback 中调用，并且必须传入该 callback 当前持有的
`Env`：

```rust
use napi_ohos::{Env, Result};
use openharmony_ability_plugin_app_control::AppControlExt;

#[napi]
pub fn terminate_application(env: Env, code: i32) -> Result<()> {
    current_app()?.terminate(&env, code)
}
```

`current_app()` 代表应用在 `#[ability]` 初始化时保存并按需读取的 `OpenHarmonyApp`。示例重点是 `Env`
只能来自当前 N-API callback，不能缓存、clone 或跨线程转移。

## 线程与生命周期限制

- 该插件不是 async API：禁止在 Rust worker、`async` future、`spawn` 任务或 `block_on` 中调用。
- `BridgeMainThread` 会校验活跃 N-API environment；bridge transport 在 native module session 初始化时
  建立，不依赖 `DefaultXComponent`。若 Ability context 未就绪、session 已关闭或 `Env` 不匹配，调用会
  立即报错。
- ArkTS 调用 `process.ProcessManager.exit(code)`。一旦系统实际结束进程，后续业务逻辑不应依赖继续执行。
- `accepted = false` 会被 Rust facade 转换为错误，不能静默忽略。

## 开发约束

`terminate` 的 request/response 都是具名 N-API object，不允许 JSON 或 Promise 包装。若未来新增控制能力，
必须仍使用 `MainThreadSyncBridge`（仅当平台要求立即决定）或单独定义异步插件 action；不能把同步 API
伪装成异步后再阻塞等待。

完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。
