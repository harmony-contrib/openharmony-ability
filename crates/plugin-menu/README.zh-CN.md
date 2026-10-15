# openharmony-ability-plugin-menu

[English](README.md) | 简体中文

管理窗口菜单栏、弹出菜单、可见性和预定义菜单动作。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-menu` |
| ArkTS HAR | `@ohos-rs/ability-plugin-menu` |
| 插件 ID | `ohos.menu` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ui-context"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-menu = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_menu::MenuBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(MenuBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { MenuPlugin } from "@ohos-rs/ability-plugin-menu";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new MenuPlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/menu/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_menu::{MenuExt, MenuSetVisibleRequest};

async fn show_menu_bar(app: &OpenHarmonyApp) -> Result<()> {
    app.menu()?.set_menubar_visible(MenuSetVisibleRequest {
        visible: true,
        window_id: "main".to_owned(),
    }).await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `set_menubar / set_menu_json` | `set-menubar` | 替换指定窗口的菜单数据。 |
| `popup` | `popup` | 在指定窗口弹出菜单。 |
| `set_menubar_visible / is_menubar_visible` | `set-menubar-visible / —` | 修改可见性，或读取 Rust 缓存。 |
| `execute_predefined` | `execute-predefined` | 执行复制、粘贴、窗口操作等预定义动作。 |

## 行为与生命周期

- 需要 `DefaultXComponent` 对应的 UI context 就绪及窗口菜单挂载回调；主窗口标识为 `main`，子窗口使用其数值 ID 的字符串。
- 菜单数据相关字段和模型见 `MenuSetMenubarRequest`、`MenuPopupRequest`、`MenuItemData` 源码；示例不需要创建新的桥接协议。
- `is_menubar_visible` 读取可见性与内容缓存，不是同步平台查询；只有最近成功更新的缓存可反映已提交状态。
- 通过 `register_menu_event_sender` 和 `register_menu_open_event_sender` 注入 crossbeam sender；第一次注册生效，业务方保留并消费 receiver。
- ArkTS 包负责菜单栏挂载、下拉状态、快捷键匹配和平台动作；core 不反向依赖菜单插件。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
