# openharmony-ability-plugin-accessibility

[English](README.md) | 简体中文

查询系统字体缩放、读屏和触摸探索状态，并订阅读屏状态变化。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-accessibility` |
| ArkTS HAR | `@ohos-rs/ability-plugin-accessibility` |
| 插件 ID | `ohos.accessibility` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ability"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-accessibility = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_accessibility::AccessibilityBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(AccessibilityBridgePlugin::new(&app))
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AccessibilityPlugin } from "@ohos-rs/ability-plugin-accessibility";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AccessibilityPlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/accessibility/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_accessibility::AccessibilityExt;

async fn font_scale(app: &OpenHarmonyApp) -> Result<f64> {
    app.accessibility()?.get_font_scale().await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `get_font_scale` | `get-font-scale` | 返回 Ability 配置中的字体缩放值。 |
| `is_open_accessibility` | `is-open-accessibility` | 查询读屏是否开启。 |
| `is_touch_explore_enabled` | `is-touch-explore-enabled` | 查询触摸探索是否开启。 |
| `subscribe_state_change / unsubscribe_state_change` | `subscribe-state-change / unsubscribe-state-change` | 注册或移除状态回调。 |

## 行为与生命周期

- 字体缩放读取 `abilityContext.config.fontSizeScale`，不需要无障碍权限；配置不可用时返回错误。
- 读屏查询使用 API 18+ 的 `isScreenReaderOpenSync`，低版本返回错误。系统权限或能力错误会向 Rust 传播，不能把失败当作“未开启”。
- `subscribe_state_change` 的回调在 N-API 主线程执行，只做轻量分发；重复订阅替换原处理器。需要停止时显式取消订阅。
- Rust 插件通过保存的 app 在 Ability session 重建后重放订阅；ArkTS 实例在销毁时移除平台监听。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
