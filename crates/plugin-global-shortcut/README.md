# openharmony-ability-plugin-global-shortcut

English | [简体中文](README.zh-CN.md)

Register system-wide shortcuts and consume trigger events through a Rust receiver.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-global-shortcut` |
| ArkTS HAR | `@ohos-rs/ability-plugin-global-shortcut` |
| Plugin ID | `ohos.global-shortcut` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ability"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-global-shortcut = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_global_shortcut::GlobalShortcutBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(GlobalShortcutBridgePlugin)
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { GlobalShortcutPlugin } from "@ohos-rs/ability-plugin-global-shortcut";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new GlobalShortcutPlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/global-shortcut/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_global_shortcut::GlobalShortcutExt;

async fn register_shortcut(app: &OpenHarmonyApp) -> Result<()> {
    let shortcuts = app.global_shortcut()?;
    let _events = shortcuts.event_receiver();
    shortcuts.register(1, &["Control".to_owned(), "Shift".to_owned()], "K").await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `register` | `register` | Register modifiers and a main key under a numeric ID. |
| `unregister / unregister_all` | `unregister / unregister-all` | Remove one shortcut or all shortcuts. |
| `event_receiver` | — (Rust-side accessor) | Get the ShortcutTriggeredEvent receiver. |

## Behavior and lifecycle

- Use `Control`, `Shift`, `Alt` or `Super`, with 1–2 modifiers per shortcut. The main key must exist in the ArkTS key-name table.
- Below API 14, registration and removal return success without performing platform operations. `Ok(())` alone does not prove that a hotkey is installed.
- Get `event_receiver()` before registration and consume it on a business worker. Each trigger produces `Pressed` followed by a synthesized `Released` event.
- ArkTS unregisters hotkeys on disposal. Multiple receivers compete for channel messages; cloning a receiver does not broadcast events.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
