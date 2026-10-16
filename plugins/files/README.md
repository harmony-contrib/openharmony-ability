# @ohos-rs/ability-plugin-files

English | [简体中文](README.zh-CN.md)

This file-dialog HAR pairs with `openharmony-ability-plugin-files`. It invokes the system open/save/folder picker using the Ability context. `DialogOptions` stays structured; filter-string conversion happens only inside ArkTS.

## Install

```bash
ohpm install @ohos-rs/ability-plugin-files
```

## Assembly

Add the HAR to the application's `oh-package.json5`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-files": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { FilesPlugin } from "@ohos-rs/ability-plugin-files";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new FilesPlugin())];
}
```

Register `FilesBridgePlugin` in Rust and call `FilesExt::show_file_dialog`. See the [Rust facade README](../../crates/plugin-files/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.files` |
| `execution` | `async` |
| `requires` | `["ability"]` |
| Actions | `file-dialog` |
| request → response | `ohos.files.DialogOptions` → `ohos.files.DialogResponse` |

`DialogOptions` includes `dialogType` (open/save/folder), `allowMany`, `defaultLocation` and `filters` (name/pattern pairs). `DialogResponse` returns `{ files: string[] }`, empty on cancellation.

## Behavior

- `dialogType` must identify a supported open/save/folder mode. Invalid type names or fields throw.
- The system `DocumentViewPicker.select(FOLDER)` determines folder support, without filtering device names. Capable tablets/2-in-1 devices can select folders. Errors retain device type, API version and platform error code.
- After the picker closes, ArkTS checks `context.isActive()`; a destroyed Ability rejects the Promise.
- Requests/responses are named N-API objects, without JSON transport.

See the [plugin development standard](../../docs/plugin-development-standard.md) for threading,
lifecycle and contract acceptance rules.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
