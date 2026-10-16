# openharmony-ability-plugin-deep-link

[English](README.md) | 简体中文

读取应用冷启动和后续 Want 中的 URI，并提供 Rust 会话内的消费式启动数据访问。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-deep-link` |
| ArkTS HAR | `@ohos-rs/ability-plugin-deep-link` |
| 插件 ID | `ohos.deep-link` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ability"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-deep-link = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_deep_link::DeepLinkBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(DeepLinkBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { DeepLinkPlugin } from "@ohos-rs/ability-plugin-deep-link";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new DeepLinkPlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/deep-link/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_deep_link::DeepLinkExt;

async fn latest_uri(app: &OpenHarmonyApp) -> Result<Option<String>> {
    app.deep_link()?.get_latest_uri().await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `get_initial_uri` | `get-initial-uri` | 读取冷启动 URI，不消费。 |
| `get_latest_uri` | `get-latest-uri` | 读取最近一次 Want URI。 |
| `take_initial_uri` | —（同步会话读取） | 取出并清空 Rust 初始 URI。 |
| `take_want_parameters` | —（同步会话读取） | 取出并清空最近一次 Want 参数数据。 |

## 行为与生命周期

- 异步 URI 查询读取 `NativeAbility` 维护的 `AppStorage` 初始/最新 URI；没有 URI 时返回 `None`。
- `take_*` 读取 Rust app 的生命周期状态，不经过 ArkTS；消费后再次读取为空字符串，与异步非消费式查询不同。
- 启动数据在对应生命周期回调到达后才可读取。保留 `NativeAbility` 的 `onCreate`、`onNewWant` 调用链。
- URI scheme 必须在应用清单中声明；本插件只读取投递数据，不会在运行时注册 scheme。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
