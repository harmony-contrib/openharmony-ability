# @ohos-rs/ability-plugin-statusbar

[English](README.md) | 简体中文

管理桌面系统状态栏（托盘）项、图标、菜单和提示，并转发点击事件。

这是 [`openharmony-ability-plugin-statusbar`](../../crates/plugin-statusbar/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-statusbar
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-statusbar": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { StatusbarPlugin } from "@ohos-rs/ability-plugin-statusbar";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new StatusbarPlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `StatusBarBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-statusbar/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.statusbar` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `add / remove` | `add / remove` | 添加或移除状态栏项。 |
| `update_icon / update_menu / update_tips` | `update-icon / update-menu / update-tips` | 更新图标、菜单或提示。 |
| `execute_predefined` | `execute-predefined` | 执行托盘菜单的预定义动作。 |

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应；平台对象留在 ArkTS。

## 运行限制

- 需要先用 `add(StatusBarAddRequest)` 创建状态栏项再更新。图标按正方形 RGBA 像素传入，可分别提供白色和黑色变体。
- 依赖目标设备提供 `DeskTopExtensionKit.statusBarManager`，主要面向桌面/2-in-1 环境，不保证所有设备支持。
- 使用 `register_icon_click_sender`、`register_menu_click_sender` 注入业务持有的 crossbeam channel；首次注册生效，消费方自行保留 receiver。
- Rust crate 和 ArkTS HAR 都依赖 menu 包共享菜单行为；如还要使用独立窗口菜单能力，另行注册 menu 插件。
- 平台添加、移除和资源处理留在 ArkTS，不能在 Rust 中保存状态栏平台对象。

当前实现见 [插件源码](src/main/ets/StatusbarPlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
