# openharmony-ability-plugin-updater

[English](README.md) | 简体中文

通过 Huawei AppGallery Update Kit 查询更新，并交给系统更新面板执行下载安装。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-updater` |
| ArkTS HAR | `@ohos-rs/ability-plugin-updater` |
| 插件 ID | `ohos.updater` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ability"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-updater = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_updater::UpdaterBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(UpdaterBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { UpdaterPlugin } from "@ohos-rs/ability-plugin-updater";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new UpdaterPlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/updater/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_updater::{CheckResult, UpdaterExt};

async fn check_update(app: &OpenHarmonyApp) -> Result<Option<CheckResult>> {
    app.updater()?.check().await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `check` | `check` | 查询更新，返回 `Option<CheckResult>`，不弹框。 |
| `download_and_install` | `downloadAndInstall` | 显示系统更新面板，后续流程由平台驱动。 |

## 行为与生命周期

- 需要目标设备提供 AppGallery Kit，并满足应用分发和更新服务的运行条件；该插件不是任意 URL 的更新器。
- `check` 返回 `Some` 表示有新版本，`None` 表示无更新；平台调用失败会返回错误。
- `CheckResult` 提供当前版本和可选目标版本、正文、日期；当前 ArkTS 实现缺少版本时使用 `unknown`，正文和日期未提供时为空。
- `download_and_install` 的成功表示系统面板已显示，不代表应用已完成安装；桥接 action 保持 `downloadAndInstall` 的现有 ABI 拼写。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
