# openharmony-ability-plugin-url

English | [简体中文](README.zh-CN.md)

`openharmony-ability-plugin-url` opens external URLs through an async Rust facade, paired
with `@ohos-rs/ability-plugin-url` and callable from Rust workers.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-url` |
| ArkTS HAR | `@ohos-rs/ability-plugin-url` |
| Plugin ID | `ohos.url` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required context | `ability` |
| action | `open-url` |
| request → response | `ohos.url.OpenRequest { url }` → `ohos.url.OpenResponse { accepted }` |

## Integration

Register both sides during application startup:

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

Add the HAR to the application's `oh-package.json5`. See the
[ArkTS README](../../plugins/url/README.md) for dependencies and setup.

## Rust usage

`UrlExt::open_url` is async and callable from a Rust worker.
The URL must be absolute and include a scheme:

```rust
use openharmony_ability_plugin_url::UrlExt;

app.open_url("https://www.openharmony.cn").await?;
```

## Threading and lifecycle constraints

- Requests/responses are owned Rust data satisfying `Send + 'static`, transferred through TSFN.
  Do not retain `Env`, `napi_value` or ArkTS objects in workers.
- ArkTS opens links with `context.openLink`. Platform failures and Ability destruction return errors.
- Arguments/results are named N-API objects, without JSON transport.

See the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
