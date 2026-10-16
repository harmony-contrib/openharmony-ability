# openharmony-ability-plugin-account

[English](README.md) | 简体中文

通过 Huawei Account Kit 完成交互式登录、静默登录和取消应用授权。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-account` |
| ArkTS HAR | `@ohos-rs/ability-plugin-account` |
| 插件 ID | `ohos.account` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ability"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-account = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_account::AccountBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(AccountBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AccountPlugin } from "@ohos-rs/ability-plugin-account";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AccountPlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/account/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_account::{AccountExt, AccountInfo};

async fn login(app: &OpenHarmonyApp) -> Result<AccountInfo> {
    app.account()?.login().await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `login` | `login` | 显示登录面板，返回 AccountInfo。 |
| `silent_login` | `silentLogin` | 不显示面板的登录。 |
| `logout` | `logout` | 取消当前应用的 Huawei Account 授权。 |

## 行为与生命周期

- 需要目标设备和应用具备 Huawei Account Kit 的运行条件；插件不代替应用侧的账号服务配置。
- 交互登录允许等待五分钟；静默登录不显示 UI，设备登录或应用授权条件不满足时会失败。
- `AccountInfo` 包含 `uid`、`open_id`、`union_id`、`display_name`、`avatar_uri`、`authorization_code` 和可选 `access_token`；平台未提供的字符串字段可能为空。
- `logout` 取消的是应用授权，不代表注销设备上的系统账号。桥接 action `silentLogin` 保持现有 ABI 拼写。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
