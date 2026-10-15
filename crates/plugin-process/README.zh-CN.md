# openharmony-ability-plugin-process

[English](README.md) | 简体中文

通过平台 appRecovery 分发应用重启请求。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-process` |
| ArkTS HAR | `@ohos-rs/ability-plugin-process` |
| 插件 ID | `ohos.process` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `[]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-process = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_process::ProcessBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(ProcessBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { ProcessPlugin } from "@ohos-rs/ability-plugin-process";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new ProcessPlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/process/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_process::ProcessExt;

async fn restart(app: &OpenHarmonyApp) -> Result<i32> {
    app.process()?.restart().await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `restart` | `restart` | 启用恢复能力并调用系统重启，返回分发结果码。 |

## 行为与生命周期

- `ProcessExt::process()` 需要活跃的桥接 session，但插件不要求 Ability、WindowStage 或 UI context gate。
- 重启由系统终止当前进程，不能依赖 `onDestroy` 或请求之后的代码完成业务清理；应在调用前完成必要保存。
- 返回码 `0` 表示请求已分发，不代表新进程已启动。本插件不提供任意进程结束或设备重启。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
