# @ohos-rs/ability-plugin-global-shortcut

English | [简体中文](README.zh-CN.md)

Register system-wide shortcuts and consume trigger events through a Rust receiver.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-global-shortcut`](../../crates/plugin-global-shortcut/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-global-shortcut
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-global-shortcut": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { GlobalShortcutPlugin } from "@ohos-rs/ability-plugin-global-shortcut";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new GlobalShortcutPlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `GlobalShortcutBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-global-shortcut/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.global-shortcut` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `register` | `register` | Register modifiers and a main key under a numeric ID. |
| `unregister / unregister_all` | `unregister / unregister-all` | Remove one shortcut or all shortcuts. |
| `event_receiver` | — (Rust-side accessor) | Get the ShortcutTriggeredEvent receiver. |

Call through the Rust facade. The host dispatches named N-API requests/responses; platform objects remain in ArkTS.

## Runtime constraints

- Use `Control`, `Shift`, `Alt` or `Super`, with 1–2 modifiers per shortcut. The main key must exist in the ArkTS key-name table.
- Below API 14, registration and removal return success without performing platform operations. `Ok(())` alone does not prove that a hotkey is installed.
- Get `event_receiver()` before registration and consume it on a business worker. Each trigger produces `Pressed` followed by a synthesized `Released` event.
- ArkTS unregisters hotkeys on disposal. Multiple receivers compete for channel messages; cloning a receiver does not broadcast events.

See the [plugin source](src/main/ets/GlobalShortcutPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
