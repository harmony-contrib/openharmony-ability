# @ohos-rs/ability-plugin-system-state

[English](README.md) | 简体中文

查询热状态、应用代码目录、显示器及可用区域，并接收系统状态变化。

这是 [`openharmony-ability-plugin-system-state`](../../crates/plugin-system-state/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-system-state
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-system-state": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { SystemStatePlugin } from "@ohos-rs/ability-plugin-system-state";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new SystemStatePlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `SystemStateBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-system-state/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.system-state` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `thermal_level` | `get-thermal-level` | 查询平台热状态等级。 |
| `bundle_code_dir` | `get-bundle-code-dir` | 查询应用代码目录。 |
| `available_area` | `get-available-area` | 查询默认显示器可用区域。 |
| `displays` | `get-displays` | 查询显示器尺寸、密度、可用区域等快照。 |

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应；平台对象留在 ArkTS。

## 运行限制

- 通过 `SystemStateClient::new(app)?` 创建 client；当前没有 `SystemStateExt` 扩展 trait。
- 热状态等级对应平台 `ThermalLevel`（0–7）。显示器尺寸和区域保留平台数值，密度由 `density_pixels` 单独提供。
- 用 `register_system_state_event_sender` 注入业务的 crossbeam sender；第一次注册生效。事件 `kind` 为 `thermal`、`sleep`、`wake`、`available-area` 或 `displays`，读取相应的可选字段。
- ArkTS 在插件安装时订阅热状态、显示器和屏幕/睡眠事件，销毁时释放监听。部分订阅失败会记录日志，不能假定每类事件都可用。

当前实现见 [插件源码](src/main/ets/SystemStatePlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
