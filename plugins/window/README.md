# @ohos-rs/ability-plugin-window

English | [简体中文](README.zh-CN.md)

This HAR pairs with `openharmony-ability-plugin-window`. It queries avoid areas for the actual window bound to the host's `DefaultXComponent` and creates/manages OS sub-windows through async platform APIs. It does not select by native-module name.

## Install

```bash
ohpm install @ohos-rs/ability-plugin-window
```

## Assembly

Add the HAR to the application's `oh-package.json5`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-window": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { WindowPlugin } from "@ohos-rs/ability-plugin-window";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new WindowPlugin())];
}
```

Register `WindowBridgePlugin` in Rust and use the matching window facade. See the [Rust facade README](../../crates/plugin-window/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.window` |
| `execution` | `async` |
| `requires` | `["ui-context"]` |
| Queries | `get-avoid-area`, `is-maximized`, `is-minimized` |
| Window actions | `create-os-window`, decorations/background/shadow, focus, move/resize, minimize/maximize/restore/show/destroy |

`get-avoid-area` returns the complete `{ visible, leftRect, topRect, rightRect, bottomRect }`. Creation returns a platform `windowId`; later operations route by that handle, not native-module configuration.

## Runtime constraints

- The plugin meets its requirements after the host's `DefaultXComponent` injects UIContext. The host waits for context or cancellation.
- One instance can hold multiple sub-windows. IDs are resolved within that instance; `onDispose` destroys its windows.
- Creation awaits move, resize, background/decorations and show before returning. A failed step releases the newly created window.
- `context.getWindow()` resolves the component's actual window; main-window geometry is not broadcast to sub-window components.
- Request/response type names must match exactly, without JSON or dynamic compatibility layers.

See the [plugin development standard](../../docs/plugin-development-standard.md) for threading,
lifecycle and contract acceptance rules.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
