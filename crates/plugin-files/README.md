# openharmony-ability-plugin-files

English | [简体中文](README.zh-CN.md)

`openharmony-ability-plugin-files` provides file dialogs (open/save/folder) through an async
Rust facade, paired with `@ohos-rs/ability-plugin-files` and callable from Rust workers.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-files` |
| ArkTS HAR | `@ohos-rs/ability-plugin-files` |
| Plugin ID | `ohos.files` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required context | `ability` |
| action | `file-dialog` |
| request → response | `ohos.files.DialogOptions` → `ohos.files.DialogResponse { files }` |

## Integration

Register both sides during application startup:

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_files::FilesBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(FilesBridgePlugin)
        .expect("files facade must be registered once");
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { FilesPlugin } from "@ohos-rs/ability-plugin-files";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new FilesPlugin())];
}
```

Add `@ohos-rs/ability-plugin-files` to the application's `oh-package.json5`.
See the [ArkTS README](../../plugins/files/README.md) for HAR dependencies and setup.

## Rust usage

`FilesExt::show_file_dialog` is async and callable from a Rust worker.
Build options with `FileDialogOptions`; ArkTS converts filter name/pattern fields to picker syntax:

```rust
use openharmony_ability_plugin_files::{
    dialog_type, FileDialogFilter, FileDialogOptions, FilesExt,
};

let options = FileDialogOptions::new(dialog_type::OPEN_FILE)
    .allow_many(true)
    .filters(vec![
        FileDialogFilter::new().name("Text").pattern("txt;md"),
        FileDialogFilter::new().name("Images").pattern("png;jpg"),
    ]);
let response = app.show_file_dialog(options).await?;
// response.files: Vec<String>, empty on cancellation
```

`dialog_type` supports `OPEN_FILE`, `SAVE_FILE` and `OPEN_FOLDER`.
`SAVE_FILE` accepts `default_location` (for example `file://docs`).
The system `DocumentViewPicker.select(FOLDER)` determines folder support without device-name
filtering. Rejections retain the platform error code, device type and API version.

## Threading and lifecycle constraints

- Requests/responses are owned Rust data satisfying `Send + 'static`, transferred through TSFN.
  Do not retain `Env`, `napi_value` or ArkTS objects in workers.
- Calls complete after the system picker closes; Ability destruction causes an error.
- Arguments/results are named N-API objects, without JSON transport.

See the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
