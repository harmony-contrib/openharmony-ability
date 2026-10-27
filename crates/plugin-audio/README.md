# openharmony-ability-plugin-audio

English | [简体中文](README.zh-CN.md)

Drive reusable, keyed `AVPlayer` media-file playback sessions across the Ability bridge with explicit file-descriptor ownership.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-audio` |
| ArkTS HAR | `@ohos-rs/ability-plugin-audio` |
| Plugin ID | `ohos.audio` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ability"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-audio = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_audio::AudioBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(AudioBridgePlugin)
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AudioPlugin } from "@ohos-rs/ability-plugin-audio";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AudioPlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/audio/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use std::os::fd::AsFd;
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_audio::{AudioClient, AudioExt, AudioUpdateRequest};

async fn play_sound(app: &OpenHarmonyApp, file: &std::fs::File) -> Result<()> {
    let client: AudioClient = app.audio()?;
    client
        .update(
            AudioUpdateRequest {
                player: "bell".into(),
                replace: true,
                release: false,
                play: true,
                volume: 0.8,
                report_errors: true,
                label: "bell.wav".into(),
            },
            Some(file.as_fd()),
        )
        .await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `AudioClient::update` | `update` | Replace, update volume/play state, or release a named media player session. |

## Behavior and lifecycle

- Pass a `BorrowedFd` separately to `AudioClient::update`; `AudioUpdateRequest` cannot carry caller-supplied descriptor integers. Keep the source open until `update` resolves.
- ArkTS duplicates the descriptor synchronously via `fs.dup` before awaiting player creation or releasing the previous player. The plugin owns the duplicated `fs.File` until the player finishes releasing and never closes the borrowed source.
- Replacement waits for the previous pipeline to release before creating another player. Clearing or releasing (`release: true` or `replace: true` with `source = None`) resolves only after cleanup completes.
- Volume must be finite and within `0.0..=1.0`; `player` must be non-empty; `source.is_some()` requires `replace: true`; `release: true` forbids both `source.is_some()` and `play: true`.
- An accepted update acknowledges descriptor duplication and schedules the player transition; it does not wait for asynchronous decoding or playback completion. `report_errors: true` logs local warnings with the SDK error and `label`.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
