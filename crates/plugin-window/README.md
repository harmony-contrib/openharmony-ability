# openharmony-ability-plugin-window

English | [简体中文](README.zh-CN.md)

`openharmony-ability-plugin-window` is an async window facade paired with
`@ohos-rs/ability-plugin-window`. Query avoid areas for the actual window containing the current
`DefaultXComponent`, or create and manage multiple OS sub-windows.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-window` |
| ArkTS HAR | `@ohos-rs/ability-plugin-window` |
| Plugin ID | `ohos.window` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required context | `ui-context` |
| Queries | `get-avoid-area`, `is-maximized`, `is-minimized` |
| Window actions | `create-os-window`, decorations/background/shadow, focus, move/resize, minimize/maximize/restore/show/destroy |

`AvoidArea` preserves `visible` and all four rectangles: `left_rect`, `top_rect`, `right_rect`
and `bottom_rect`. Do not drop fields when migrating helpers. Requests/responses use named
N-API objects without JSON.

## Integration

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_window::WindowBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(WindowBridgePlugin)
        .expect("window facade must be registered once");
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { WindowPlugin } from "@ohos-rs/ability-plugin-window";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new WindowPlugin())];
}
```

## Rust usage

```rust
use openharmony_ability::{AvoidAreaType, OpenHarmonyApp};
use openharmony_ability_plugin_window::{WindowCreateRequest, WindowExt};
use napi_ohos::Result;

async fn open_tools(app: &OpenHarmonyApp) -> Result<()> {
    let window = app.window()?;
    let area = window.query_avoid_area(AvoidAreaType::Keyboard).await?;
    let id = window
        .create_os_window(WindowCreateRequest {
            name: "tools".to_owned(),
            width: 720,
            height: 480,
            x: 80,
            y: 80,
            decorations: true,
            transparent: false,
            background_color: Some(0xff202020),
        })
        .await?;
    window.move_window_to(id, 120, 120).await?;
    println!("keyboard inset: {}", area.bottom_rect.height);
    Ok(())
}
```

## Calls and lifecycle

- `WindowClient` retains only a worker-safe `BridgeRuntime`; platform `Window` objects stay in ArkTS.
- Plugins do not read native-module names. Each instance maintains its own platform-window-ID
  map and can create multiple sub-windows without overwriting another instance's calls.
- The host context gate manages calls before UI readiness; cancelled calls or destroyed sessions
  cannot publish stale results.
- `onDispose` destroys sub-windows created by that instance. Unknown or released IDs fail explicitly.
- `context.getWindow()` resolves the component's actual window, so main/sub-window components
  receive their own avoid areas.

See the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
