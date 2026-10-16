# @ohos-rs/ability-plugin-autostart

English | [简体中文](README.zh-CN.md)

Open system startup-management settings and query this application's autostart status.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-autostart`](../../crates/plugin-autostart/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-autostart
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-autostart": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AutostartPlugin } from "@ohos-rs/ability-plugin-autostart";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AutostartPlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `AutostartBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-autostart/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.autostart` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `enable` | `enable` | Open startup settings so the user can enable autostart. |
| `disable` | `disable` | Open the same settings so the user can disable autostart. |
| `is_enabled` | `is-enabled` | Query this application's autostart status. |

Call through the Rust facade. The host dispatches named N-API requests/responses; platform objects remain in ArkTS.

## Runtime constraints

- Both `enable` and `disable` open settings. Success means the page opened; it does not guarantee the setting changed.
- Rust returns `false` below API 21. ArkTS also returns `false` when the capability is unsupported or a query fails, so the value cannot distinguish all unavailable states.
- The current settings route is `pc_app_setup_settings`. Verify that this page is available on the target device.

See the [plugin source](src/main/ets/AutostartPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
