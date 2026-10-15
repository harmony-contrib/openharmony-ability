# @ohos-rs/ability-plugin-process

English | [简体中文](README.zh-CN.md)

Dispatch application restart through the platform appRecovery API.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-process`](../../crates/plugin-process/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-process
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-process": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { ProcessPlugin } from "@ohos-rs/ability-plugin-process";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new ProcessPlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `ProcessBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-process/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.process` |
| `execution` | `async` |
| `requires` | `[]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `restart` | `restart` | Enable recovery and request a system restart, returning the dispatch code. |

Call through the Rust facade. The host dispatches named N-API requests/responses; platform objects remain in ArkTS.

## Runtime constraints

- `ProcessExt::process()` needs an active bridge session, but the plugin has no Ability, WindowStage or UI-context requirement.
- The system terminates the current process on restart. Save necessary state before calling; do not depend on `onDestroy` or subsequent code for cleanup.
- A return code of `0` means the request was dispatched, not that the replacement process has started. The plugin does not kill arbitrary processes or reboot the device.

See the [plugin source](src/main/ets/ProcessPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
