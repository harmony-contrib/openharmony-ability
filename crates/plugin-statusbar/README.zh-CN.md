# openharmony-ability-plugin-statusbar

[English](README.md) | 简体中文

管理桌面系统状态栏（托盘）项、图标、菜单和提示，并转发点击事件。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-statusbar` |
| ArkTS HAR | `@ohos-rs/ability-plugin-statusbar` |
| 插件 ID | `ohos.statusbar` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ability"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-statusbar = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_statusbar::StatusBarBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(StatusBarBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { StatusbarPlugin } from "@ohos-rs/ability-plugin-statusbar";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new StatusbarPlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/statusbar/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_statusbar::{StatusBarExt, StatusBarUpdateTipsRequest};

async fn update_tooltip(app: &OpenHarmonyApp) -> Result<()> {
    app.statusbar()?.update_tips(StatusBarUpdateTipsRequest {
        tips: "应用运行中".to_owned(),
    }).await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `add / remove` | `add / remove` | 添加或移除状态栏项。 |
| `update_icon / update_menu / update_tips` | `update-icon / update-menu / update-tips` | 更新图标、菜单或提示。 |
| `execute_predefined` | `execute-predefined` | 执行托盘菜单的预定义动作。 |

## 行为与生命周期

- 需要先用 `add(StatusBarAddRequest)` 创建状态栏项再更新。图标按正方形 RGBA 像素传入，可分别提供白色和黑色变体。
- 依赖目标设备提供 `DeskTopExtensionKit.statusBarManager`，主要面向桌面/2-in-1 环境，不保证所有设备支持。
- 使用 `register_icon_click_sender`、`register_menu_click_sender` 注入业务持有的 crossbeam channel；首次注册生效，消费方自行保留 receiver。
- Rust crate 和 ArkTS HAR 都依赖 menu 包共享菜单行为；如还要使用独立窗口菜单能力，另行注册 menu 插件。
- 平台添加、移除和资源处理留在 ArkTS，不能在 Rust 中保存状态栏平台对象。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
