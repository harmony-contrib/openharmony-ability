# openharmony-ability-plugin-process

English | [简体中文](README.zh-CN.md)

Dispatch application restart through the platform appRecovery API.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-process` |
| ArkTS HAR | `@ohos-rs/ability-plugin-process` |
| Plugin ID | `ohos.process` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `[]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-process = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_process::ProcessBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(ProcessBridgePlugin)
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { ProcessPlugin } from "@ohos-rs/ability-plugin-process";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new ProcessPlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/process/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_process::ProcessExt;

async fn restart(app: &OpenHarmonyApp) -> Result<i32> {
    app.process()?.restart().await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `restart` | `restart` | Enable recovery and request a system restart, returning the dispatch code. |

## Behavior and lifecycle

- `ProcessExt::process()` needs an active bridge session, but the plugin has no Ability, WindowStage or UI-context requirement.
- The system terminates the current process on restart. Save necessary state before calling; do not depend on `onDestroy` or subsequent code for cleanup.
- A return code of `0` means the request was dispatched, not that the replacement process has started. The plugin does not kill arbitrary processes or reboot the device.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
