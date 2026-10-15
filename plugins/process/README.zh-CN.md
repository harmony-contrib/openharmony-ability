# @ohos-rs/ability-plugin-process

[English](README.md) | 简体中文

通过平台 appRecovery 分发应用重启请求。

这是 [`openharmony-ability-plugin-process`](../../crates/plugin-process/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-process
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-process": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { ProcessPlugin } from "@ohos-rs/ability-plugin-process";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new ProcessPlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `ProcessBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-process/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.process` |
| `execution` | `async` |
| `requires` | `[]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `restart` | `restart` | 启用恢复能力并调用系统重启，返回分发结果码。 |

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应；平台对象留在 ArkTS。

## 运行限制

- `ProcessExt::process()` 需要活跃的桥接 session，但插件不要求 Ability、WindowStage 或 UI context gate。
- 重启由系统终止当前进程，不能依赖 `onDestroy` 或请求之后的代码完成业务清理；应在调用前完成必要保存。
- 返回码 `0` 表示请求已分发，不代表新进程已启动。本插件不提供任意进程结束或设备重启。

当前实现见 [插件源码](src/main/ets/ProcessPlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
