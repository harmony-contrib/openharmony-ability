# openharmony-ability-plugin-fault-injection

[English](README.md) | 简体中文

为桥接调用设置可控的失败、异常、延迟或超时，用于集成测试与故障覆盖。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-fault-injection` |
| ArkTS HAR | `@ohos-rs/ability-plugin-fault-injection` |
| 插件 ID | `ohos.fault-injection` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `[]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-fault-injection = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_fault_injection::FaultInjectionBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(FaultInjectionBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { FaultInjectionPlugin } from "@ohos-rs/ability-plugin-fault-injection";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new FaultInjectionPlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/faultinjection/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_fault_injection::{
    FaultInjectionExt, FaultOutcomeWire, FaultRuleWire,
};

async fn fail_once(app: &OpenHarmonyApp, plugin_id: &str, action: &str) -> Result<()> {
    app.fault_injection()?
        .set_fault_rule(FaultRuleWire {
            plugin_id: plugin_id.to_owned(),
            action: Some(action.to_owned()),
            outcome: FaultOutcomeWire {
                kind: "error".to_owned(),
                code: Some(42),
                message: Some("injected failure".to_owned()),
                ms: None,
            },
            hits: Some(1),
        })
        .await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `set_fault_rule` | `enable + set-rule` | 启用注册表并安装一条规则。 |
| `clear_fault_rules` | `clear` | 清空规则，保持注册表启用。 |

## 行为与生命周期

- 按 `plugin_id` 和可选 `action` 匹配；`hits` 为正数时按次数消耗，省略时持续生效。被测试的目标插件也需要正常注册。
- 注册表默认关闭；`set_fault_rule` 会先启用。`clear_fault_rules` 只清规则，不等同于 `disable`。
- `error`、`exception` 适用于同步/异步调用；`delay`、`timeout` 仅作用于异步分发。同步路径会消耗这两类规则但继续调用。
- ArkTS 在 `onInstall` 中使用通用 `registerDispatchHook` 接入；core 不依赖此测试插件。规则注册表是模块级状态，可跨 Ability session 保留。
- ArkTS 还提供 `disable` action；Rust 高层 facade 当前仅暴露设置规则和清空规则。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
