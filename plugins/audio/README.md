# @ohos-rs/ability-plugin-audio

English | [简体中文](README.zh-CN.md)

Drive reusable, keyed `AVPlayer` media-file playback sessions with explicit file-descriptor ownership.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-audio`](../../crates/plugin-audio/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-audio
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-audio": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AudioPlugin } from "@ohos-rs/ability-plugin-audio";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AudioPlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `AudioBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-audio/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.audio` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `AudioClient::update` | `update` | Replace, update volume/play state, or release a named media player session. |

Call through the Rust facade. The host dispatches named N-API requests/responses (`ohos.audio.UpdateRequest` → `ohos.audio.UpdateResponse`); platform objects remain in ArkTS.

## Runtime constraints

- Pass a `BorrowedFd` separately to `AudioClient::update`; playback options cannot contain caller-supplied descriptor integers. Keep the source open until the update acknowledges it.
- ArkTS duplicates the descriptor synchronously with `fs.dup` before awaiting player creation or releasing the previous player. The plugin retains the resulting `fs.File` until its player finishes releasing and never closes the borrowed source.
- Replacement waits for the previous pipeline to release before creating another player. Clearing or releasing a player acknowledges only after cleanup. Disposal waits for pending creation and replacement.
- Failed creation, configuration, preparation, playback, and decoder callbacks release the player and close its duplicate. SDK duplication errors reject the update unchanged and leave the existing player intact.
- An accepted update acknowledges ownership and schedules playback; it does not claim that asynchronous decoding or playback succeeded. `reportErrors` enables local warnings containing the SDK error and source label.

See the [plugin source](src/main/ets/AudioPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
