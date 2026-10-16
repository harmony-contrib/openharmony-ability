# openharmony-ability-plugin-clipboard

English | [简体中文](README.zh-CN.md)

Read and write system clipboard text, HTML, images, file URIs and ordered multi-record content asynchronously.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-clipboard` |
| ArkTS HAR | `@ohos-rs/ability-plugin-clipboard` |
| Plugin ID | `ohos.clipboard` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ability"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-clipboard = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_clipboard::ClipboardBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(ClipboardBridgePlugin::default())
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new ClipboardPlugin({ metadataMimeType: "application/x-my-app-metadata-v1" }))];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/clipboard/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_clipboard::ClipboardExt;

async fn copy_and_read(app: &OpenHarmonyApp) -> Result<Option<String>> {
    let clipboard = app.clipboard()?;
    clipboard.write_text("Hello OpenHarmony").await?;
    clipboard.read_text().await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `read_text / write_text` | `read-text / write-text` | Read or write text; an empty clipboard returns None. |
| `read_content / read_records` | `read-content / read-records` | Read aggregate content or ordered native records. |
| `write_records` | `write-records` | Write 1–512 records, with optional text metadata. |
| `write_image / write_encoded_image` | `write-image / write-encoded-image` | Write RGBA pixels or an encoded image. |
| `write_uris / write_html / clear` | `write-uris / write-html / clear` | Write file URIs or HTML, or clear the clipboard. |

## Behavior and lifecycle

- The ArkTS factory requires the application's `metadataMimeType`. Readers and writers exchanging metadata must use the same MIME; see the ArkTS README for validation rules.
- Each `ClipboardRecord` must contain exactly one of `text`, `encoded_image` or `uri`. `metadata` is valid only with text. File URIs use `file://`.
- `write_image` requires exactly `width * height * 4` bytes. Platform PixelMaps stay in ArkTS and are released by the operation.
- Blocked reads return diagnostics for permission/signing ACL failures. Check `ohos.permission.READ_PASTEBOARD` and the signing profile.
- The revision counter belongs to the registered `ClipboardBridgePlugin::revision()`, not `ClipboardClient`. Retrieve the instance through `app.registered_plugin::<ClipboardBridgePlugin>()?`.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
