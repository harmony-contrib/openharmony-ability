# openharmony-ability-plugin-deep-link

English | [简体中文](README.zh-CN.md)

Read cold-start and subsequent Want URIs, with consuming accessors for Rust session launch data.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-deep-link` |
| ArkTS HAR | `@ohos-rs/ability-plugin-deep-link` |
| Plugin ID | `ohos.deep-link` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ability"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

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

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { DeepLinkPlugin } from "@ohos-rs/ability-plugin-deep-link";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new DeepLinkPlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/deep-link/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_deep_link::DeepLinkExt;

async fn latest_uri(app: &OpenHarmonyApp) -> Result<Option<String>> {
    app.deep_link()?.get_latest_uri().await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `get_initial_uri` | `get-initial-uri` | Read the cold-start URI without consuming it. |
| `get_latest_uri` | `get-latest-uri` | Read the latest Want URI. |
| `take_initial_uri` | — (Rust-side accessor) | Take and clear the initial URI in Rust. |
| `take_want_parameters` | — (Rust-side accessor) | Take and clear the latest Want parameter data. |

## Behavior and lifecycle

- Async URI queries read the initial/latest URI in `AppStorage`, maintained by `NativeAbility`. Missing URIs return `None`.
- `take_*` reads Rust app lifecycle state without an ArkTS round trip. A second read returns an empty string; these accessors differ from the non-consuming async queries.
- Launch data becomes available after the corresponding lifecycle callback. Preserve the `NativeAbility.onCreate` and `onNewWant` call chain.
- Declare URI schemes in the application manifest. This plugin reads delivered data and does not register schemes at runtime.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
