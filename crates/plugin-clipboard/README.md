# openharmony-ability-plugin-clipboard

Native-only system clipboard access through `OH_Pasteboard` and scoped UDMF owners.
The paired HAR retains `ohos.clipboard` / async / `["ability"]` registration identity,
but transports no clipboard data and installs no observer.

## Integration

Use the Rust crate and HAR from the **same source revision**. Bindings PR
[#187](https://github.com/ohos-rs/ohos-native-bindings/pull/187) is pinned until release;
published pasteboard/UDMF 0.0.7 alone does not contain the required APIs.

```rust
use openharmony_ability_plugin_clipboard::{ClipboardBridgePlugin, ClipboardExt};

app.register_plugin(ClipboardBridgePlugin::default())?;
let clipboard = app.clipboard()?
    .with_metadata_mime_type("application/x-my-app-metadata-v1")?;
clipboard.write_text("Hello OpenHarmony").await?;
let records = clipboard.read_records().await?;
```

```ts
import { LazyPlugin } from "@ohos-rs/ability";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";

new LazyPlugin(() => new ClipboardPlugin());
```

Metadata configuration is optional until a record contains metadata. Readers and
writers must configure the same custom MIME in Rust. Metadata is raw UTF-8, without
a version prefix or legacy fallback; an empty metadata value is an unsupported empty
opaque representation, not a missing value.

## Public API and transport

- `write_mime(Vec<ClipboardMimeContent>)` commits multiple representations in **one**
  native record. An empty vector clears the board.
- `read_mime(mimes, list)` returns present representations in request order, choosing
  the first matching record. Missing/unreadable individual entries remain absent.
  Overall native reads and authorization failures return explicit errors.
- `read_records` / `write_records` preserve native record order. A record contains
  exactly one of text, encoded image or `file://` URI; only text may carry metadata.
  `read_records` is a convenience projection (text, then image, then URI).
  Use `read_mime` when every representation matters.
- `read_text`, `read_content`, `write_text`, `write_html`, `write_encoded_image`,
  `write_image`, `write_uris` and `clear` remain available. Encoded images are opaque
  and never decoded or reencoded. `write_image` alone losslessly encodes explicit
  RGBA input as PNG in Rust; it does not project other MIME entries into PixelMaps.
  `read_content.png` contains only existing PNG bytes, not synthesized conversions.
- Public operations return `Result<T, ClipboardError>`, not `napi_ohos::Result<T>`.

The async API shape is retained, but each operation runs **synchronous native IPC
when polled**. Call it on the application's existing worker/executor. This crate
does not spawn a thread, add an executor, call `block_on`, retain an `Env` or cache
native handles. Awaiting a write returns only after `OH_Pasteboard_SetData` completes;
there is no per-client/global write queue or cross-worker ordering policy.
Clipboard data belongs to the system service, not an Ability session.

## Formats, limits and empty values

Plain text (`text/plain` ↔ `general.plain-text`) uses `UdsPlainText` on both paths.
HTML (`text/html` ↔ `general.html`) uses `UdsHtml`. They must be valid UTF-8 without
embedded NUL; invalid text returns `ClipboardError::InvalidText`, never lossy decoding.
Empty text/HTML uses those typed APIs; if rejected, `EmptyBinaryUnsupported` is returned.

All other formats use general entries: PNG/JPEG/GIF/WebP/BMP/TIFF/SVG and file URI
MIME names map to their standard UTD identifiers; custom names are preserved.
Nonempty binary bytes, including embedded NUL and multiple encoded images, are exact.
There is no PixelMap read fallback or custom byte framing.

**Breaking:** empty opaque/binary values return
`ClipboardError::EmptyBinaryUnsupported { mime }`. The native implementation of
[`OH_UdmfRecord_AddGeneralEntry`](https://github.com/openharmony/distributeddatamgr_udmf/blob/master/framework/ndkimpl/data/udmf.cpp)
rejects `count == 0`. No private marker or fake custom type is used to disguise this
platform limitation. Empty text is present; an absent entry remains absent.

Limits remain 512 representations and 1024 **UTF-8 bytes** per MIME; record batches
contain 1–512 records. Duplicate representations after MIME/UTD mapping are rejected.
Platform size/type restrictions can still cause explicit native errors.

## Authorization and revision (breaking)

`read_authorized_records` always returns `ClipboardError::AuthorizationRequired`.
There is no implicit platform permission prompt. Obtain temporary native paste access
or arrange `ohos.permission.READ_PASTEBOARD` with the application's permission flow
and signing-profile ACL, then call `read_records`.

`ClipboardBridgePlugin::revision() -> Result<u32>` is a native **pull** query.
Enable crate feature `api-18` and require runtime API 18. Zero returns
`ClipboardError::RevisionUnavailable`, not a valid revision; the native API uses zero
for an unknown/failed query. Service/system restart may decrease/reset the count;
clearing data does not reset it. No subscription or event bridge exists.

Base data operations require API 13. Feature `api-14` enables metadata-only native
MIME listing; `api-18` includes it. Without `api-14`, listing uses the native data
snapshot and therefore needs read access. All feature defaults are off.

## Breaking migration and validation

Remove ArkTS constructor options and `ClipboardPluginOptions`. Move configuration
to `with_metadata_mime_type`. All old clipboard bridge actions/request-response
envelopes and `ChangedEvent` are withdrawn; retained value types keep their names.
Upgrade Rust/HAR together, handle typed errors and choose caller-side permission
and scheduling policy.

`pnpm test` discovers the real HAR/BridgeHost rejection tests and runs the production
Rust MIME policy directly with `rustc --test`; no native FFI is faked. ARM64 OHOS
builds compile the real native adapter. Host policy tests and cross-compilation
do **not** constitute device clipboard acceptance.
