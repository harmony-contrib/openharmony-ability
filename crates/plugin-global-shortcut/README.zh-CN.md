# openharmony-ability-plugin-global-shortcut

[English](README.md) | 简体中文

注册系统级快捷键，并通过 Rust 接收端消费按键触发事件。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-global-shortcut` |
| ArkTS HAR | `@ohos-rs/ability-plugin-global-shortcut` |
| 插件 ID | `ohos.global-shortcut` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ability"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-global-shortcut = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_global_shortcut::GlobalShortcutBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(GlobalShortcutBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { GlobalShortcutPlugin } from "@ohos-rs/ability-plugin-global-shortcut";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new GlobalShortcutPlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/global-shortcut/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_global_shortcut::GlobalShortcutExt;

async fn register_shortcut(app: &OpenHarmonyApp) -> Result<()> {
    let shortcuts = app.global_shortcut()?;
    let _events = shortcuts.event_receiver();
    shortcuts.register(1, &["Control".to_owned(), "Shift".to_owned()], "K").await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `register` | `register` | 按数值 ID 注册修饰键和主键组合。 |
| `unregister / unregister_all` | `unregister / unregister-all` | 移除指定或全部快捷键。 |
| `event_receiver` | —（Rust channel） | 取得 ShortcutTriggeredEvent 接收端。 |

## 行为与生命周期

- 修饰键使用 `Control`、`Shift`、`Alt`、`Super`，每个组合需要 1–2 个修饰键；主键须存在于 ArkTS 实现的键名表。
- API 14 以下注册和注销直接返回成功且不执行平台操作，不能仅凭 `Ok(())` 判断已安装系统快捷键。
- 在注册前取得 `event_receiver()`，在业务 worker 中消费接收端；每次触发包含 `Pressed` 和合成的 `Released` 事件。
- ArkTS 在销毁插件时注销全部热键。多个接收者会竞争消费 channel，不能把 clone 当成事件广播。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
