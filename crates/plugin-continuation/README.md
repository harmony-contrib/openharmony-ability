# openharmony-ability-plugin-continuation

English | [简体中文](README.zh-CN.md)

Read system continuation restore state and pre-register the source-device snapshot. This synchronous Rust facade uses core lifecycle state; it has no separate ArkTS HAR, BridgePlugin or outbound action.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-continuation` |
| Platform integration | `NativeAbility.onCreate` / `onNewWant` / `onContinue` |
| Execution | Synchronous Rust app-state access; the source snapshot is read through a core export |
| Plugin registration | No additional registration |

## Integration

```toml
[dependencies]
openharmony-ability-plugin-continuation = "1.0.0-beta.3"
```

Keep the application's existing `NativeAbility` and `#[ability]` lifecycle integration. There is no `ContinuationBridgePlugin` or ArkTS factory to create.

## Rust usage

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_continuation::{set_continuation_data, ContinuationExt};

fn restore(app: &OpenHarmonyApp) -> Option<String> {
    let continuation = app.continuation();
    if continuation.is_continuation_restore() {
        Some(continuation.take_continuation_data())
    } else {
        None
    }
}

fn prepare_snapshot(snapshot: String) {
    set_continuation_data(snapshot);
}
```

| API | Behavior |
| --- | --- |
| `is_continuation_restore` | Read the restore flag without consuming data. |
| `take_continuation_data` | Take and clear restore data; subsequent calls return an empty string. |
| `set_continuation_data` | Replace the process-level source snapshot for a later system `onContinue` call. |

## Timing and constraints

- Restore data becomes available after Ability lifecycle delivery. Do not assume cold-start continuation state is ready during initialization/setup.
- `onContinue` reads the source snapshot synchronously without consuming it, allowing retries after cancellation. An empty snapshot causes the callback to refuse migration.
- This crate does not validate snapshot size or the application data format. The application must respect the platform budget and interpret restored data.
- Continuation is initiated by system UI; this facade has no API to initiate device-to-device migration.

See the [Rust source](src/lib.rs) and [ArkTS runtime](../../native_ability/README.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
