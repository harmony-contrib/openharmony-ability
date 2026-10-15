# Clipboard plugin

Each factory must configure its text metadata MIME through the constructor options object:

```ts
import { LazyPlugin } from "@ohos-rs/ability";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";

new LazyPlugin(() => new ClipboardPlugin({ metadataMimeType: "application/x-my-app-metadata-v1" }));
```

The instance uses this MIME for writing and reading the `metadata` field of text records.
Writers and readers sharing custom metadata must use the same MIME. Metadata is UTF-8
encoded with the framework's version byte, including when the metadata string is empty.
Use a custom `type/subtype` without MIME parameters, up to 1024 ASCII characters.
The constructor rejects platform content MIME types and the legacy unversioned metadata MIME.

The framework provides no default MIME. Reads also accept
`application/x-gpui-ohos-text-metadata-v1` and the original
unversioned `application/x-gpui-ohos-text-metadata` so existing clipboard contents remain readable.
Platform text, HTML, URI and image records use the SDK's standard content types.
