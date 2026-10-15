# openharmony-ability-plugin-autostart

English | [简体中文](README.zh-CN.md)

Open system startup-management settings and query this application's autostart status.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-autostart` |
| ArkTS HAR | `@ohos-rs/ability-plugin-autostart` |
| Plugin ID | `ohos.autostart` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ability"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-autostart = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_autostart::AutostartBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(AutostartBridgePlugin)
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AutostartPlugin } from "@ohos-rs/ability-plugin-autostart";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AutostartPlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/autostart/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_autostart::AutostartExt;

async fn open_startup_settings(app: &OpenHarmonyApp) -> Result<()> {
    app.autostart()?.enable().await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `enable` | `enable` | Open startup settings so the user can enable autostart. |
| `disable` | `disable` | Open the same settings so the user can disable autostart. |
| `is_enabled` | `is-enabled` | Query this application's autostart status. |

## Behavior and lifecycle

- Both `enable` and `disable` open settings. Success means the page opened; it does not guarantee the setting changed.
- Rust returns `false` below API 21. ArkTS also returns `false` when the capability is unsupported or a query fails, so the value cannot distinguish all unavailable states.
- The current settings route is `pc_app_setup_settings`. Verify that this page is available on the target device.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
