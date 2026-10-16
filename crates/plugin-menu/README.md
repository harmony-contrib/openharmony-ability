# openharmony-ability-plugin-menu

English | [简体中文](README.zh-CN.md)

Manage window menu bars, popup menus, visibility and predefined menu actions.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-menu` |
| ArkTS HAR | `@ohos-rs/ability-plugin-menu` |
| Plugin ID | `ohos.menu` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ui-context"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-menu = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_menu::MenuBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(MenuBridgePlugin)
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { MenuPlugin } from "@ohos-rs/ability-plugin-menu";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new MenuPlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/menu/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_menu::{MenuExt, MenuSetVisibleRequest};

async fn show_menu_bar(app: &OpenHarmonyApp) -> Result<()> {
    app.menu()?.set_menubar_visible(MenuSetVisibleRequest {
        visible: true,
        window_id: "main".to_owned(),
    }).await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `set_menubar / set_menu_json` | `set-menubar` | Replace menu data for a window. |
| `popup` | `popup` | Show a popup menu in a window. |
| `set_menubar_visible / is_menubar_visible` | `set-menubar-visible / —` | Set visibility or read the Rust cache. |
| `execute_predefined` | `execute-predefined` | Execute predefined clipboard or window actions. |

## Behavior and lifecycle

- The component UI context and the window's menu-mount callback must be ready. Use `main` for the main window and a numeric ID string for sub-windows.
- See `MenuSetMenubarRequest`, `MenuPopupRequest` and `MenuItemData` in the source for menu data fields and models. The example needs no new bridge protocol.
- `is_menubar_visible` reads visibility/content caches, not the platform synchronously. Caches reflect successful submitted updates.
- Inject crossbeam senders with `register_menu_event_sender` and `register_menu_open_event_sender`. The first registration wins; the consumer retains and drains its receiver.
- ArkTS owns menu mounting, dropdown state, accelerator matching and platform actions. The core does not depend on the menu plugin.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
