# @ohos-rs/ability-plugin-system-state

English | [简体中文](README.zh-CN.md)

Query thermal state, the bundle code directory, displays and available areas, and receive system changes.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-system-state`](../../crates/plugin-system-state/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-system-state
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-system-state": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { SystemStatePlugin } from "@ohos-rs/ability-plugin-system-state";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new SystemStatePlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `SystemStateBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-system-state/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.system-state` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `thermal_level` | `get-thermal-level` | Query the platform thermal level. |
| `bundle_code_dir` | `get-bundle-code-dir` | Query the bundle code directory. |
| `available_area` | `get-available-area` | Query the default display's available area. |
| `displays` | `get-displays` | Query display size, density and available-area snapshots. |

Call through the Rust facade. The host dispatches named N-API requests/responses; platform objects remain in ArkTS.

## Runtime constraints

- Construct the client with `SystemStateClient::new(app)?`. There is no `SystemStateExt` trait.
- Thermal values follow platform `ThermalLevel` (0–7). Display sizes/areas retain platform numeric values; density is provided separately as `density_pixels`.
- Inject consumer-owned crossbeam senders with `register_system_state_event_sender` / `register_media_command_event_sender` (re-registration replaces the active sender; call the `unregister_*` helpers on teardown). Event `kind` is one of `thermal`, `sleep`, `wake`, `lock-screen`, `unlock-screen`, `locale`, `power-source`, `network`, `available-area`, `displays`, or `suspend-delay-expired`.
- `request-suspend-delay` / `cancel-suspend-delay` use dedicated `SuspendDelayRequest`/`Response` and `CancelSuspendDelayRequest`/`Response` types; the timeout callback automatically calls `backgroundTaskManager.cancelSuspendDelay` and emits `"suspend-delay-expired"`.
- `set-now-playing` uses `media_command` bitmask flags (`PLAY`, `PAUSE`, `STOP`, `NEXT`, `PREVIOUS`, `SEEK`, `ALL`) to toggle AVSession transport control listeners dynamically.
- ArkTS subscribes to thermal, display and screen/sleep events during installation and releases listeners on disposal. Some subscription failures are logged; not every event source is guaranteed.

See the [plugin source](src/main/ets/SystemStatePlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).

## Idle sleep prevention

`prevent-sleep` accepts `ohos.system-state.PreventSleepRequest { reason }` and returns `PreventSleepResponse { id }`; `release-sleep` accepts `ReleaseSleepRequest { id }` and returns `ReleaseSleepResponse { accepted }`. Each ID owns a separate API 23+ `BACKGROUND_USER_IDLE` running lock. It does not keep the display on. Applications must declare `ohos.permission.RUNNING_LOCK`; unsupported device profiles and denied permissions return errors. Reasons must contain 1–256 non-control characters.

The plugin requires its forced-sleep subscription before acquiring a lock and releases all locks on forced sleep or disposal. Release is idempotent, including after forced sleep. A cancelled acquisition never holds a lock after its asynchronous creation finishes. These source contracts require runtime verification on the selected device profile.
