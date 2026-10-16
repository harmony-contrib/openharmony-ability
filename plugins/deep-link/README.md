# @ohos-rs/ability-plugin-deep-link

English | [简体中文](README.zh-CN.md)

Read cold-start and subsequent Want URIs, with consuming accessors for Rust session launch data.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-deep-link`](../../crates/plugin-deep-link/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-deep-link
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-deep-link": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { DeepLinkPlugin } from "@ohos-rs/ability-plugin-deep-link";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new DeepLinkPlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `DeepLinkBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-deep-link/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.deep-link` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `get_initial_uri` | `get-initial-uri` | Read the cold-start URI without consuming it. |
| `get_latest_uri` | `get-latest-uri` | Read the latest Want URI. |
| `take_initial_uri` | — (Rust-side accessor) | Take and clear the initial URI in Rust. |
| `take_want_parameters` | — (Rust-side accessor) | Take and clear the latest Want parameter data. |

Call through the Rust facade. The host dispatches named N-API requests/responses; platform objects remain in ArkTS.

## Runtime constraints

- Async URI queries read the initial/latest URI in `AppStorage`, maintained by `NativeAbility`. Missing URIs return `None`.
- `take_*` reads Rust app lifecycle state without an ArkTS round trip. A second read returns an empty string; these accessors differ from the non-consuming async queries.
- Launch data becomes available after the corresponding lifecycle callback. Preserve the `NativeAbility.onCreate` and `onNewWant` call chain.
- Declare URI schemes in the application manifest. This plugin reads delivered data and does not register schemes at runtime.

See the [plugin source](src/main/ets/DeepLinkPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
