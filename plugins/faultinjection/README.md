# @ohos-rs/ability-plugin-fault-injection

English | [简体中文](README.zh-CN.md)

Inject controlled bridge failures, exceptions, delays and timeouts for integration testing.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-fault-injection`](../../crates/plugin-fault-injection/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-fault-injection
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-fault-injection": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { FaultInjectionPlugin } from "@ohos-rs/ability-plugin-fault-injection";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new FaultInjectionPlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `FaultInjectionBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-fault-injection/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.fault-injection` |
| `execution` | `async` |
| `requires` | `[]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `set_fault_rule` | `enable + set-rule` | Enable the registry and install one rule. |
| `clear_fault_rules` | `clear` | Clear all rules while keeping the registry enabled. |

ArkTS also supports `disable`, which disables and clears the registry.

Call through the Rust facade. The host dispatches named N-API requests/responses; platform objects remain in ArkTS.

## Runtime constraints

- Rules match `plugin_id` and optional `action`. Positive `hits` values limit matching calls; omitted `hits` persists until cleared. Register the target plugin normally.
- The registry starts disabled. `set_fault_rule` enables it first; `clear_fault_rules` clears rules without disabling the registry.
- `error` and `exception` apply to sync and async dispatch. `delay` and `timeout` affect async calls only; sync dispatch consumes these rules and continues without blocking.
- ArkTS registers a generic `registerDispatchHook` during `onInstall`; the core does not depend on this test plugin. The module-level rule registry can survive Ability sessions.
- ArkTS also exposes `disable`. The Rust convenience facade currently exposes only setting and clearing rules.

See the [plugin source](src/main/ets/FaultInjectionPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
