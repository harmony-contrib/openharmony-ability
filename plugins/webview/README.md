# @ohos-rs/ability-plugin-webview

English | [简体中文](README.zh-CN.md)

This HAR pairs with `openharmony-ability-plugin-webview`. It creates ArkWeb `Web` and
`WebviewController` objects, mounts the WebView FrameNode into the native module's component
root or an `ohos.node` container, and forwards controller operations/callbacks through named N-API.

Application code uses controller IDs rather than retaining controllers or embedding WebView
interfaces back into `DefaultXComponent`. Page `Stack` declaration order controls layering.

## Install

```bash
ohpm install @ohos-rs/ability-plugin-webview
```

## Assembly

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-webview": "1.0.0-beta.3",
  },
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { WebviewPlugin } from "@ohos-rs/ability-plugin-webview";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new WebviewPlugin())];
}
```

Register `WebviewBridgePlugin` in the Rust `#[ability]` initializer and declare custom schemes
there with `WebviewProtocol::register`. See the
[Rust facade README](../../crates/plugin-webview/README.md).

## Plugin and actions

| Field | Value |
| --- | --- |
| `id` | `ohos.webview` |
| `execution` | `async` |
| `requires` | `["ui-context"]` |
| Mount | Current module/component root (full-screen by default), or optional `parentHandle` container |
| Creation | `create`: `CreateRequest { id, parentHandle? }` → `CreateResponse { id }` |
| Controller actions | `set-visible`, `set-background-color`, `remove`, `load-url`, `load-html`, `set-zoom`, `reload`, `focus`, `get-url`, `cookies-with-url`, `clear-all-browsing-data`, `evaluate-script` |

Every action validates `BridgeTypedValue.typeName` and returns its declared response type.
Creation waits for controller attachment, delegate/protocol/proxy installation and initial
load startup; it does not return success merely after scheduling future rendering.

## Mounting and mixed layouts

The host mounts a WebView FrameNode under a unique internal key in its component root,
full-screen by default. For composition, Rust creates an `ohos.node` container and passes its
handle as `parentHandle`; the WebView mounts below it. Rust mounts the container as a whole
with `mount-into-root`.

Place application content before/after `DefaultXComponent` in a `Stack` for lower/upper layers:

```ts
Stack() {
  this.BusinessUnderlay()                        // Below the plugin tree
  DefaultXComponent({ moduleName: "demo_native" })
  this.BusinessForeground()                      // Above the plugin tree
}
```

Each component needs a distinct native module, including components in different windows.
There are no `windowKey`/`surfaceKey` routes. A module/component may host multiple WebViews by ID.
IDs are opaque facade-local business identifiers, not node keys or process-global ArkWeb tags.
The HAR combines session identity with a process counter for unique tags, so instances may reuse
the same business ID safely.

No timer is required for mounting: the module root exists before `ui-context-ready`.
On Ability/session disposal, the HAR removes its nodes and controller state through
`context.removeChild` or parent-container detachment, leaving business/other-plugin nodes intact.

## ArkWeb callbacks, custom protocols and JavaScript

- Rust declares callback subscriptions before creation. The HAR installs delegates from this
  snapshot and uses `context.invokeNativeSync` to deliver navigation, download start/end, title
  and engine/controller lifecycle events to Rust `on_main_thread_event`.
- Navigation is fail-open on missing/failed callbacks; download start is fail-closed.
  Notification failures are logged. Controller events include the native tag; Rust validates
  the current generation. Old navigation events fail-open, old download starts fail-closed,
  and stale notifications are discarded.
- Schemes must be registered before process-wide engine startup. The first creation broadcasts
  named engine events to active matching facades, seals/validates declarations and flushes them.
  Identical scheme/options declarations remain idempotent after Ability reconstruction.
  New schemes after startup fail; late facades may reuse only identical existing declarations.
  Conflicting options for a scheme fail before initialization.
  After attachment, protocol/proxy/delegate installation precedes initial navigation.
- URL custom protocols handle resource requests; `window.<object>.<method>()` proxies handle
  page-to-Rust method calls.
- Creation preserves `transparent(true)`: use a transparent background when no explicit color
  was supplied.

See the [plugin development standard](../../docs/plugin-development-standard.md) for reverse
type names, threading, lifecycle, node cleanup and acceptance criteria.

## Native-tree embedding

See the [Rust native embedding contract](../../crates/plugin-webview/README.md#native-tree-embedding)
for scoped clients, controller declarations, document options and retirement.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
