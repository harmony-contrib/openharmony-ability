# @ohos-rs/ability-plugin-autostart

[English](README.md) | 简体中文

打开系统应用启动管理设置，并查询当前应用的自启动状态。

这是 [`openharmony-ability-plugin-autostart`](../../crates/plugin-autostart/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-autostart
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-autostart": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AutostartPlugin } from "@ohos-rs/ability-plugin-autostart";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AutostartPlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `AutostartBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-autostart/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.autostart` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `enable` | `enable` | 打开启动管理页面，由用户开启自启动。 |
| `disable` | `disable` | 打开同一设置页面，由用户关闭自启动。 |
| `is_enabled` | `is-enabled` | 查询本应用的自启动状态。 |

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应；平台对象留在 ArkTS。

## 运行限制

- `enable` 和 `disable` 都是设置入口，成功只表示页面已打开，不保证开关已改变。
- 状态查询由 Rust 在 API 21 以下直接返回 `false`；ArkTS 在平台不支持或查询失败时也返回 `false`，不能据此区分所有不可用原因。
- 设置跳转使用当前实现的 `pc_app_setup_settings` 入口，需在目标设备验证该页面是否可用。

当前实现见 [插件源码](src/main/ets/AutostartPlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
