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
- During installation and configuration updates, the plugin synchronously queries the Rust owner's live routes through the named `subscriptions-ready` event. Surviving subscriptions are restored without a worker, executor, or queued replay.

See the [plugin source](src/main/ets/AccessibilityPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).

## Announcements and reduced motion

`AccessibilityClient::send_event(AccessibilitySendEventRequest)` sends exactly one
announcement or nonnegative native accessibility element ID on API 12.
`announce_live(text, assertive)` uses API-18 live-announcement interruption policy.
`observe_reduce_motion(handler)` requires API 23 and returns an
`AccessibilityMotionObservation`. Initial state and changes use one ordered
UI-thread callback. The handler must not block or reenter the bridge.

Each registered Rust plugin owns its observations; the matching ArkTS instance
uses one system listener for all subscribed motion routes. Rust Drop immediately
retires delivery without platform work. On the next notification, Rust returns
`EventAcknowledgement { accepted: false }` for a retired ID; ArkTS removes it and
unsubscribes the exact system callback when the last route is gone. Configuration
updates also reconcile routes. Await `observation.close()` for prompt platform
unsubscribe; disposal removes all remaining session listeners. Failed `off`
retains callback identity for retry and is reported. No application animation,
announcement throttling, or observer-budget policy is applied.

**Migration:** ship the Rust crate and HAR together. Installation now requires
`ohos.accessibility.SubscriptionsRequest {}` ->
`ohos.accessibility.Subscriptions { screenReader, motionIds }` through the existing
scoped synchronous bridge event route. Existing announcement/motion action names
and fields remain stable. Drop no longer queues cleanup; the demo's stop action
awaits `close()` and returns `Promise<void>`. Screen-reader unsubscribe now uses
the owner's exact callback rather than removing other instances' listeners.

The repository demo has announcement and reduced-motion observe/stop buttons.
The PR CI runs `node --test plugins/accessibility/tests/*.test.mjs` and
`bash crates/plugin-accessibility/tests/run-motion-host.sh`.
