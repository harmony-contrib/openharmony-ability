# @ohos-rs/ability-plugin-menu

English | [简体中文](README.zh-CN.md)

Manage window menu bars, popup menus, visibility and predefined menu actions.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-menu`](../../crates/plugin-menu/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-menu
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-menu": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { MenuPlugin } from "@ohos-rs/ability-plugin-menu";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new MenuPlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `MenuBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-menu/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.menu` |
| `execution` | `async` |
| `requires` | `["ui-context"]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `set_menubar / set_menu_json` | `set-menubar` | Replace menu data for a window. |
| `popup` | `popup` | Show a popup menu in a window. |
| `set_menubar_visible / is_menubar_visible` | `set-menubar-visible / —` | Set visibility or read the Rust cache. |
| `execute_predefined` | `execute-predefined` | Execute predefined clipboard or window actions. |

Call through the Rust facade. The host dispatches named N-API requests/responses; platform objects remain in ArkTS.

## Runtime constraints

- The component UI context and the window's menu-mount callback must be ready. Use `main` for the main window and a numeric ID string for sub-windows.
- See `MenuSetMenubarRequest`, `MenuPopupRequest` and `MenuItemData` in the source for menu data fields and models. The example needs no new bridge protocol.
- `is_menubar_visible` reads visibility/content caches, not the platform synchronously. Caches reflect successful submitted updates.
- Inject crossbeam senders with `register_menu_event_sender` and `register_menu_open_event_sender`. The first registration wins; the consumer retains and drains its receiver.
- ArkTS owns menu mounting, dropdown state, accelerator matching and platform actions. The core does not depend on the menu plugin.

See the [plugin source](src/main/ets/MenuPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
