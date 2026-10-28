# @ohos-rs/ability-plugin-clipboard

English | [简体中文](README.zh-CN.md)

This HAR pairs with `openharmony-ability-plugin-clipboard`. It supplies registration
identity only: clipboard data operations all run through the Rust facade's native
`OH_Pasteboard` path. The HAR imports no pasteboard, transports no clipboard data,
shows no permission prompt, converts no images and installs no change observer.

## Install

```bash
ohpm install @ohos-rs/ability-plugin-clipboard
```

## Assembly

Add the HAR to the application's `oh-package.json5`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.4",
    "@ohos-rs/ability-plugin-clipboard": "1.0.0-beta.4"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new ClipboardPlugin())];
}
```

Register `ClipboardBridgePlugin` in Rust and call the clipboard facade there. See the
[Rust facade README](../../crates/plugin-clipboard/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.clipboard` |
| `execution` | `async` |
| `requires` | `["ability"]` |

The HAR has no clipboard actions. `invokeAsync` rejects every action with an error
directing the caller to the native Rust facade; this is intentional, not a fallback
path. Read and write text, HTML, encoded images, URIs and multi-MIME records through
`ClipboardClient`.

## Runtime constraints

- Configure the metadata MIME in Rust with
  `ClipboardClient::with_metadata_mime_type`; the HAR constructor takes no options.
- Upgrade the Rust crate and the HAR from the **same source revision**.
- `read_authorized_records` never prompts. Obtain native paste access or
  `ohos.permission.READ_PASTEBOARD` through the application's permission flow, then
  call `read_records`.
- Revision reading is a native pull query (crate feature `api-18`); there is no bridge
  subscription or change event.

See the [plugin development standard](../../docs/plugin-development-standard.md) for
threading, lifecycle and contract acceptance rules.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
