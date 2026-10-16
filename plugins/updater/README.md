# @ohos-rs/ability-plugin-updater

English | [简体中文](README.zh-CN.md)

Query updates through Huawei AppGallery Update Kit and let the system update dialog drive download and installation.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-updater`](../../crates/plugin-updater/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-updater
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-updater": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { UpdaterPlugin } from "@ohos-rs/ability-plugin-updater";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new UpdaterPlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `UpdaterBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-updater/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.updater` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `check` | `check` | Query without a dialog, returning `Option<CheckResult>`. |
| `download_and_install` | `downloadAndInstall` | Show the system update dialog; the platform drives the remaining flow. |

Call through the Rust facade. The host dispatches named N-API requests/responses; platform objects remain in ArkTS.

## Runtime constraints

- The device must provide AppGallery Kit and satisfy application distribution/update-service requirements. This plugin does not install updates from arbitrary URLs.
- `check` returns `Some` when an update exists and `None` otherwise; platform failures return errors.
- `CheckResult` includes the current version and optional target version, body and date. The current ArkTS implementation uses `unknown` when version information is unavailable and leaves body/date absent.
- `download_and_install` success means the system dialog opened, not that installation finished. The bridge retains the ABI spelling `downloadAndInstall`.

See the [plugin source](src/main/ets/UpdaterPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
