# openharmony-ability-plugin-system-state

[English](README.md) | 简体中文

查询热状态、应用代码目录、显示器及可用区域，并接收系统状态变化。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-system-state` |
| ArkTS HAR | `@ohos-rs/ability-plugin-system-state` |
| 插件 ID | `ohos.system-state` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ability"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-system-state = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_system_state::SystemStateBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(SystemStateBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { SystemStatePlugin } from "@ohos-rs/ability-plugin-system-state";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new SystemStatePlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/system-state/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_system_state::{DisplaySnapshot, SystemStateClient};

async fn displays(app: &OpenHarmonyApp) -> Result<Vec<DisplaySnapshot>> {
    SystemStateClient::new(app)?.displays().await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `thermal_level` | `get-thermal-level` | 查询平台热状态等级。 |
| `bundle_code_dir` | `get-bundle-code-dir` | 查询应用代码目录。 |
| `available_area` | `get-available-area` | 查询默认显示器可用区域。 |
| `displays` | `get-displays` | 查询显示器尺寸、密度、可用区域等快照。 |

## 行为与生命周期

- 通过 `SystemStateClient::new(app)?` 创建 client；当前没有 `SystemStateExt` 扩展 trait。
- 热状态等级对应平台 `ThermalLevel`（0–7）。显示器尺寸和区域保留平台数值，密度由 `density_pixels` 单独提供。
- 用 `register_system_state_event_sender` 注入业务的 crossbeam sender；第一次注册生效。事件 `kind` 为 `thermal`、`sleep`、`wake`、`available-area` 或 `displays`，读取相应的可选字段。
- ArkTS 在插件安装时订阅热状态、显示器和屏幕/睡眠事件，销毁时释放监听。部分订阅失败会记录日志，不能假定每类事件都可用。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
