# @ohos-rs/ability-plugin-global-shortcut

[English](README.md) | 简体中文

注册系统级快捷键，并通过 Rust 接收端消费按键触发事件。

这是 [`openharmony-ability-plugin-global-shortcut`](../../crates/plugin-global-shortcut/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-global-shortcut
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-global-shortcut": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { GlobalShortcutPlugin } from "@ohos-rs/ability-plugin-global-shortcut";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new GlobalShortcutPlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `GlobalShortcutBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-global-shortcut/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.global-shortcut` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `register` | `register` | 按数值 ID 注册修饰键和主键组合。 |
| `unregister / unregister_all` | `unregister / unregister-all` | 移除指定或全部快捷键。 |
| `event_receiver` | —（Rust channel） | 取得 ShortcutTriggeredEvent 接收端。 |

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应；平台对象留在 ArkTS。

## 运行限制

- 修饰键使用 `Control`、`Shift`、`Alt`、`Super`，每个组合需要 1–2 个修饰键；主键须存在于 ArkTS 实现的键名表。
- API 14 以下注册和注销直接返回成功且不执行平台操作，不能仅凭 `Ok(())` 判断已安装系统快捷键。
- 在注册前取得 `event_receiver()`，在业务 worker 中消费接收端；每次触发包含 `Pressed` 和合成的 `Released` 事件。
- ArkTS 在销毁插件时注销全部热键。多个接收者会竞争消费 channel，不能把 clone 当成事件广播。

当前实现见 [插件源码](src/main/ets/GlobalShortcutPlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
