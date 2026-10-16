# @ohos-rs/ability-plugin-accessibility

English | [简体中文](README.zh-CN.md)

Query system font scale, screen-reader and touch-exploration state, and subscribe to screen-reader changes.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-accessibility`](../../crates/plugin-accessibility/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-accessibility
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-accessibility": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AccessibilityPlugin } from "@ohos-rs/ability-plugin-accessibility";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AccessibilityPlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `AccessibilityBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-accessibility/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.accessibility` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `get_font_scale` | `get-font-scale` | Read font scale from the Ability configuration. |
| `is_open_accessibility` | `is-open-accessibility` | Query whether the screen reader is enabled. |
| `is_touch_explore_enabled` | `is-touch-explore-enabled` | Query whether touch exploration is enabled. |
| `subscribe_state_change / unsubscribe_state_change` | `subscribe-state-change / unsubscribe-state-change` | Install or remove a state-change callback. |

Call through the Rust facade. The host dispatches named N-API requests/responses; platform objects remain in ArkTS.

## Runtime constraints

- Font scale comes from `abilityContext.config.fontSizeScale` and requires no accessibility permission; unavailable configuration produces an error.
- The screen-reader query uses API 18+ `isScreenReaderOpenSync` and fails on older systems. Permission/capability failures propagate to Rust; a failed query does not mean accessibility is disabled.
- `subscribe_state_change` runs its handler on the N-API main thread. Keep it lightweight; a new subscription replaces the previous handler. Unsubscribe explicitly when finished.
- The Rust plugin retains the app to replay subscriptions after an Ability session rebuild. The ArkTS instance removes its platform listener on disposal.

See the [plugin source](src/main/ets/AccessibilityPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
