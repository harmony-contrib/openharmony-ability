# openharmony-ability-plugin-url

`openharmony-ability-plugin-url` 提供打开外部 URL 的 Rust facade。它与 ArkTS HAR
`@ohos-rs/ability-plugin-url` 成对使用，是异步插件，可从 Rust worker 调用。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-url` |
| ArkTS HAR | `@ohos-rs/ability-plugin-url` |
| 插件 ID | `ohos.url` |
| 执行模式 | 异步：`AsyncBridge` / `invokeAsync` |
| 前置 context | `ability` |
| action | `open-url` |
| request → response | `ohos.url.OpenRequest { url }` → `ohos.url.OpenResponse { accepted }` |

## 接入

Rust facade 和 ArkTS factory 都必须在应用启动期装配：

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_url::UrlBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(UrlBridgePlugin)
        .expect("url facade must be registered once");
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { UrlPlugin } from "@ohos-rs/ability-plugin-url";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new UrlPlugin())];
}
```

同时在应用 `oh-package.json5` 添加 `@ohos-rs/ability-plugin-url`。HAR 的具体依赖和 plugin 说明见
[ArkTS README](../../plugins/url/README.md)。

## Rust 使用方式

`UrlExt::open_url` 是异步 facade，可在 Rust worker 中调用；`url` 必须是带 scheme 的绝对 URL：

```rust
use openharmony_ability_plugin_url::UrlExt;

app.open_url("https://www.openharmony.cn").await?;
```

## 线程与生命周期限制

- 异步 action：request/response 必须是 `Send + 'static` 的 Rust 所有权数据，经 TSFN 传输；不保存
  `Env`、`napi_value` 或 ArkTS 对象到 worker。
- ArkTS 侧通过 `context.openLink` 打开；调用失败或 Ability 销毁时返回明确错误。
- 参数与结果都是具名 N-API object，不存在 JSON transport。

完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。
