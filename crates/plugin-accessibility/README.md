# openharmony-ability-plugin-accessibility

English | [简体中文](README.zh-CN.md)

Query system font scale, screen-reader and touch-exploration state, and subscribe to screen-reader changes.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-accessibility` |
| ArkTS HAR | `@ohos-rs/ability-plugin-accessibility` |
| Plugin ID | `ohos.accessibility` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ability"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-accessibility = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_accessibility::AccessibilityBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(AccessibilityBridgePlugin::new(&app))
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AccessibilityPlugin } from "@ohos-rs/ability-plugin-accessibility";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AccessibilityPlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/accessibility/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_accessibility::AccessibilityExt;

async fn font_scale(app: &OpenHarmonyApp) -> Result<f64> {
    app.accessibility()?.get_font_scale().await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `get_font_scale` | `get-font-scale` | Read font scale from the Ability configuration. |
| `is_open_accessibility` | `is-open-accessibility` | Query whether the screen reader is enabled. |
| `is_touch_explore_enabled` | `is-touch-explore-enabled` | Query whether touch exploration is enabled. |
| `subscribe_state_change / unsubscribe_state_change` | `subscribe-state-change / unsubscribe-state-change` | Install or remove a state-change callback. |

## Behavior and lifecycle

- Font scale comes from `abilityContext.config.fontSizeScale` and requires no accessibility permission; unavailable configuration produces an error.
- The screen-reader query uses API 18+ `isScreenReaderOpenSync` and fails on older systems. Permission/capability failures propagate to Rust; a failed query does not mean accessibility is disabled.
- `subscribe_state_change` runs its handler on the N-API main thread. Keep it lightweight; a new subscription replaces the previous handler. Unsubscribe explicitly when finished.
- The Rust plugin retains the app to replay subscriptions after an Ability session rebuild. The ArkTS instance removes its platform listener on disposal.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
