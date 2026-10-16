# openharmony-ability-plugin-statusbar

English | [简体中文](README.zh-CN.md)

Manage desktop status-bar (tray) items, icons, menus and tooltips, and forward click events.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-statusbar` |
| ArkTS HAR | `@ohos-rs/ability-plugin-statusbar` |
| Plugin ID | `ohos.statusbar` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ability"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-statusbar = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_statusbar::StatusBarBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(StatusBarBridgePlugin)
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { StatusbarPlugin } from "@ohos-rs/ability-plugin-statusbar";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new StatusbarPlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/statusbar/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_statusbar::{StatusBarExt, StatusBarUpdateTipsRequest};

async fn update_tooltip(app: &OpenHarmonyApp) -> Result<()> {
    app.statusbar()?.update_tips(StatusBarUpdateTipsRequest {
        tips: "应用运行中".to_owned(),
    }).await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `add / remove` | `add / remove` | Add or remove the status-bar item. |
| `update_icon / update_menu / update_tips` | `update-icon / update-menu / update-tips` | Update icons, menus or tooltips. |
| `execute_predefined` | `execute-predefined` | Execute predefined tray-menu actions. |

## Behavior and lifecycle

- Call `add(StatusBarAddRequest)` before updates. Icons are square RGBA pixel buffers, with optional white and black variants.
- The target device must provide `DeskTopExtensionKit.statusBarManager`. This is primarily a desktop/2-in-1 capability and is not guaranteed on every device.
- Inject consumer-owned crossbeam channels with `register_icon_click_sender` and `register_menu_click_sender`. The first registration wins; keep the receiver alive.
- Both Rust and ArkTS depend on the menu package for shared behavior. Register the menu plugin separately if the application also uses window menus.
- Platform item creation/removal and resources stay in ArkTS; do not retain platform status-bar objects in Rust.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
