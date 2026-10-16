# openharmony-ability-plugin-notification

[English](README.md) | 简体中文

发布和撤销系统通知，并通过应用配置的 URI scheme 接收通知点击。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-notification` |
| ArkTS HAR | `@ohos-rs/ability-plugin-notification` |
| 插件 ID | `ohos.notification` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ability"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-notification = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_notification::NotificationBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(NotificationBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { NotificationPlugin } from "@ohos-rs/ability-plugin-notification";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new NotificationPlugin({ scheme: "my-app-notification" }))];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/notification/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_notification::{NotificationClient, ShowNotificationRequest};

async fn notify(app: &OpenHarmonyApp) -> Result<bool> {
    NotificationClient::new(app)?.show(ShowNotificationRequest {
        tag: "download-complete".to_owned(),
        title: "下载完成".to_owned(),
        body: "文件已保存".to_owned(),
        actions: vec![],
    }).await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `NotificationClient::show` | `show` | 发布带标签、标题、正文和按钮的通知。 |
| `NotificationClient::dismiss` | `dismiss` | 按标签撤销通知。 |

## 行为与生命周期

- 本 crate 通过 `NotificationClient::new(app)?` 创建 client，没有 `NotificationExt` 扩展 trait。
- `tag`、`title`、`body` 不得为空；最多三个 action，每项 `id`、`label` 不得为空。发布返回平台 `accepted` 布尔值。
- ArkTS factory 必须配置应用的 `scheme`，并由业务处理对应 `onNewWant`；通知正文与按钮点击使用同一响应 URI 格式，详见 ArkTS README。
- `show` 允许最多两分钟等待平台授权交互；实际通知展示由系统授权和运行条件决定。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
