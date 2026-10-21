# Clipboard registration plugin

`ClipboardPlugin` retains `ohos.clipboard` / async / `["ability"]` identity for paired
registration. All clipboard data operations use the Rust facade's native
`OH_Pasteboard` path. The HAR contains no pasteboard import, data transport,
permission prompt, image conversion, observer or legacy fallback.

```ts
import { LazyPlugin } from "@ohos-rs/ability";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";

new LazyPlugin(() => new ClipboardPlugin());
```

**Breaking:** remove `ClipboardPluginOptions` and the constructor options argument.
Configure metadata in Rust using `ClipboardClient::with_metadata_mime_type`.
All former ArkTS clipboard actions explicitly fail. Upgrade the Rust package and
HAR from the **same source revision**; do not mix old and new data contracts.

See the [Rust README](../../crates/plugin-clipboard/README.md) for MIME mapping,
typed empty-binary errors, explicit application-owned authorization, caller-owned
scheduling and the API-18 pull revision contract. There is no change subscription.

`pnpm test` runs production HAR/BridgeHost tests proving registration works while
every former clipboard data action is rejected without importing platform APIs.
