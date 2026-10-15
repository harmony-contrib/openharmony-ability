# openharmony-ability-plugin-system-state

English | [简体中文](README.zh-CN.md)

Query thermal state, the bundle code directory, displays and available areas, and receive system changes.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-system-state` |
| ArkTS HAR | `@ohos-rs/ability-plugin-system-state` |
| Plugin ID | `ohos.system-state` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ability"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-system-state = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_system_state::SystemStateBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(SystemStateBridgePlugin)
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { SystemStatePlugin } from "@ohos-rs/ability-plugin-system-state";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new SystemStatePlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/system-state/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_system_state::{DisplaySnapshot, SystemStateClient};

async fn displays(app: &OpenHarmonyApp) -> Result<Vec<DisplaySnapshot>> {
    SystemStateClient::new(app)?.displays().await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `thermal_level` | `get-thermal-level` | Query the platform thermal level. |
| `bundle_code_dir` | `get-bundle-code-dir` | Query the bundle code directory. |
| `available_area` | `get-available-area` | Query the default display's available area. |
| `displays` | `get-displays` | Query display size, density and available-area snapshots. |

## Behavior and lifecycle

- Construct the client with `SystemStateClient::new(app)?`. There is no `SystemStateExt` trait.
- Thermal values follow platform `ThermalLevel` (0–7). Display sizes/areas retain platform numeric values; density is provided separately as `density_pixels`.
- Inject a consumer-owned crossbeam sender with `register_system_state_event_sender`; the first registration wins. Event `kind` is `thermal`, `sleep`, `wake`, `available-area` or `displays`; inspect the corresponding optional fields.
- ArkTS subscribes to thermal, display and screen/sleep events during installation and releases listeners on disposal. Some subscription failures are logged; not every event source is guaranteed.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
