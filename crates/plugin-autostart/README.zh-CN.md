# openharmony-ability-plugin-autostart

[English](README.md) | 简体中文

打开系统应用启动管理设置，并查询当前应用的自启动状态。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-autostart` |
| ArkTS HAR | `@ohos-rs/ability-plugin-autostart` |
| 插件 ID | `ohos.autostart` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ability"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-autostart = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_autostart::AutostartBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(AutostartBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AutostartPlugin } from "@ohos-rs/ability-plugin-autostart";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AutostartPlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/autostart/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_autostart::AutostartExt;

async fn open_startup_settings(app: &OpenHarmonyApp) -> Result<()> {
    app.autostart()?.enable().await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `enable` | `enable` | 打开启动管理页面，由用户开启自启动。 |
| `disable` | `disable` | 打开同一设置页面，由用户关闭自启动。 |
| `is_enabled` | `is-enabled` | 查询本应用的自启动状态。 |

## 行为与生命周期

- `enable` 和 `disable` 都是设置入口，成功只表示页面已打开，不保证开关已改变。
- 状态查询由 Rust 在 API 21 以下直接返回 `false`；ArkTS 在平台不支持或查询失败时也返回 `false`，不能据此区分所有不可用原因。
- 设置跳转使用当前实现的 `pc_app_setup_settings` 入口，需在目标设备验证该页面是否可用。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
