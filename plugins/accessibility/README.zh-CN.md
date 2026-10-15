# @ohos-rs/ability-plugin-accessibility

[English](README.md) | 简体中文

查询系统字体缩放、读屏和触摸探索状态，并订阅读屏状态变化。

这是 [`openharmony-ability-plugin-accessibility`](../../crates/plugin-accessibility/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-accessibility
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-accessibility": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AccessibilityPlugin } from "@ohos-rs/ability-plugin-accessibility";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AccessibilityPlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `AccessibilityBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-accessibility/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.accessibility` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `get_font_scale` | `get-font-scale` | 返回 Ability 配置中的字体缩放值。 |
| `is_open_accessibility` | `is-open-accessibility` | 查询读屏是否开启。 |
| `is_touch_explore_enabled` | `is-touch-explore-enabled` | 查询触摸探索是否开启。 |
| `subscribe_state_change / unsubscribe_state_change` | `subscribe-state-change / unsubscribe-state-change` | 注册或移除状态回调。 |

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应；平台对象留在 ArkTS。

## 运行限制

- 字体缩放读取 `abilityContext.config.fontSizeScale`，不需要无障碍权限；配置不可用时返回错误。
- 读屏查询使用 API 18+ 的 `isScreenReaderOpenSync`，低版本返回错误。系统权限或能力错误会向 Rust 传播，不能把失败当作“未开启”。
- `subscribe_state_change` 的回调在 N-API 主线程执行，只做轻量分发；重复订阅替换原处理器。需要停止时显式取消订阅。
- Rust 插件通过保存的 app 在 Ability session 重建后重放订阅；ArkTS 实例在销毁时移除平台监听。

当前实现见 [插件源码](src/main/ets/AccessibilityPlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
