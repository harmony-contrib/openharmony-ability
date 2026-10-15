# @ohos-rs/ability-plugin-fault-injection

[English](README.md) | 简体中文

为桥接调用设置可控的失败、异常、延迟或超时，用于集成测试与故障覆盖。

这是 [`openharmony-ability-plugin-fault-injection`](../../crates/plugin-fault-injection/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-fault-injection
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-fault-injection": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { FaultInjectionPlugin } from "@ohos-rs/ability-plugin-fault-injection";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new FaultInjectionPlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `FaultInjectionBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-fault-injection/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.fault-injection` |
| `execution` | `async` |
| `requires` | `[]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `set_fault_rule` | `enable + set-rule` | 启用注册表并安装一条规则。 |
| `clear_fault_rules` | `clear` | 清空规则，保持注册表启用。 |

ArkTS 还支持 `disable`，用于关闭并清空注入注册表。

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应；平台对象留在 ArkTS。

## 运行限制

- 按 `plugin_id` 和可选 `action` 匹配；`hits` 为正数时按次数消耗，省略时持续生效。被测试的目标插件也需要正常注册。
- 注册表默认关闭；`set_fault_rule` 会先启用。`clear_fault_rules` 只清规则，不等同于 `disable`。
- `error`、`exception` 适用于同步/异步调用；`delay`、`timeout` 仅作用于异步分发。同步路径会消耗这两类规则但继续调用。
- ArkTS 在 `onInstall` 中使用通用 `registerDispatchHook` 接入；core 不依赖此测试插件。规则注册表是模块级状态，可跨 Ability session 保留。
- ArkTS 还提供 `disable` action；Rust 高层 facade 当前仅暴露设置规则和清空规则。

当前实现见 [插件源码](src/main/ets/FaultInjectionPlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
