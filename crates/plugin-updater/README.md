# openharmony-ability-plugin-updater

English | [简体中文](README.zh-CN.md)

Query updates through Huawei AppGallery Update Kit and let the system update dialog drive download and installation.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-updater` |
| ArkTS HAR | `@ohos-rs/ability-plugin-updater` |
| Plugin ID | `ohos.updater` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ability"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-updater = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_updater::UpdaterBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(UpdaterBridgePlugin)
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { UpdaterPlugin } from "@ohos-rs/ability-plugin-updater";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new UpdaterPlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/updater/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_updater::{CheckResult, UpdaterExt};

async fn check_update(app: &OpenHarmonyApp) -> Result<Option<CheckResult>> {
    app.updater()?.check().await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `check` | `check` | Query without a dialog, returning `Option<CheckResult>`. |
| `download_and_install` | `downloadAndInstall` | Show the system update dialog; the platform drives the remaining flow. |

## Behavior and lifecycle

- The device must provide AppGallery Kit and satisfy application distribution/update-service requirements. This plugin does not install updates from arbitrary URLs.
- `check` returns `Some` when an update exists and `None` otherwise; platform failures return errors.
- `CheckResult` includes the current version and optional target version, body and date. The current ArkTS implementation uses `unknown` when version information is unavailable and leaves body/date absent.
- `download_and_install` success means the system dialog opened, not that installation finished. The bridge retains the ABI spelling `downloadAndInstall`.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
