# openharmony-ability-plugin-fault-injection

English | [简体中文](README.zh-CN.md)

Inject controlled bridge failures, exceptions, delays and timeouts for integration testing.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-fault-injection` |
| ArkTS HAR | `@ohos-rs/ability-plugin-fault-injection` |
| Plugin ID | `ohos.fault-injection` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `[]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-fault-injection = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_fault_injection::FaultInjectionBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(FaultInjectionBridgePlugin)
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { FaultInjectionPlugin } from "@ohos-rs/ability-plugin-fault-injection";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new FaultInjectionPlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/faultinjection/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_fault_injection::{
    FaultInjectionExt, FaultOutcomeWire, FaultRuleWire,
};

async fn fail_once(app: &OpenHarmonyApp, plugin_id: &str, action: &str) -> Result<()> {
    app.fault_injection()?
        .set_fault_rule(FaultRuleWire {
            plugin_id: plugin_id.to_owned(),
            action: Some(action.to_owned()),
            outcome: FaultOutcomeWire {
                kind: "error".to_owned(),
                code: Some(42),
                message: Some("injected failure".to_owned()),
                ms: None,
            },
            hits: Some(1),
        })
        .await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `set_fault_rule` | `enable + set-rule` | Enable the registry and install one rule. |
| `clear_fault_rules` | `clear` | Clear all rules while keeping the registry enabled. |

## Behavior and lifecycle

- Rules match `plugin_id` and optional `action`. Positive `hits` values limit matching calls; omitted `hits` persists until cleared. Register the target plugin normally.
- The registry starts disabled. `set_fault_rule` enables it first; `clear_fault_rules` clears rules without disabling the registry.
- `error` and `exception` apply to sync and async dispatch. `delay` and `timeout` affect async calls only; sync dispatch consumes these rules and continues without blocking.
- ArkTS registers a generic `registerDispatchHook` during `onInstall`; the core does not depend on this test plugin. The module-level rule registry can survive Ability sessions.
- ArkTS also exposes `disable`. The Rust convenience facade currently exposes only setting and clearing rules.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
