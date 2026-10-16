# @ohos-rs/ability-plugin-updater

[English](README.md) | 简体中文

通过 Huawei AppGallery Update Kit 查询更新，并交给系统更新面板执行下载安装。

这是 [`openharmony-ability-plugin-updater`](../../crates/plugin-updater/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-updater
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-updater": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { UpdaterPlugin } from "@ohos-rs/ability-plugin-updater";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new UpdaterPlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `UpdaterBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-updater/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.updater` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `check` | `check` | 查询更新，返回 `Option<CheckResult>`，不弹框。 |
| `download_and_install` | `downloadAndInstall` | 显示系统更新面板，后续流程由平台驱动。 |

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应；平台对象留在 ArkTS。

## 运行限制

- 需要目标设备提供 AppGallery Kit，并满足应用分发和更新服务的运行条件；该插件不是任意 URL 的更新器。
- `check` 返回 `Some` 表示有新版本，`None` 表示无更新；平台调用失败会返回错误。
- `CheckResult` 提供当前版本和可选目标版本、正文、日期；当前 ArkTS 实现缺少版本时使用 `unknown`，正文和日期未提供时为空。
- `download_and_install` 的成功表示系统面板已显示，不代表应用已完成安装；桥接 action 保持 `downloadAndInstall` 的现有 ABI 拼写。

当前实现见 [插件源码](src/main/ets/UpdaterPlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
