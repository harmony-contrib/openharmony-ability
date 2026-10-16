# @ohos-rs/ability-plugin-statusbar

English | [简体中文](README.zh-CN.md)

Manage desktop status-bar (tray) items, icons, menus and tooltips, and forward click events.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-statusbar`](../../crates/plugin-statusbar/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-statusbar
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-statusbar": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { StatusbarPlugin } from "@ohos-rs/ability-plugin-statusbar";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new StatusbarPlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `StatusBarBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-statusbar/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.statusbar` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `add / remove` | `add / remove` | Add or remove the status-bar item. |
| `update_icon / update_menu / update_tips` | `update-icon / update-menu / update-tips` | Update icons, menus or tooltips. |
| `execute_predefined` | `execute-predefined` | Execute predefined tray-menu actions. |

Call through the Rust facade. The host dispatches named N-API requests/responses; platform objects remain in ArkTS.

## Runtime constraints

- Call `add(StatusBarAddRequest)` before updates. Icons are square RGBA pixel buffers, with optional white and black variants.
- The target device must provide `DeskTopExtensionKit.statusBarManager`. This is primarily a desktop/2-in-1 capability and is not guaranteed on every device.
- Inject consumer-owned crossbeam channels with `register_icon_click_sender` and `register_menu_click_sender`. The first registration wins; keep the receiver alive.
- Both Rust and ArkTS depend on the menu package for shared behavior. Register the menu plugin separately if the application also uses window menus.
- Platform item creation/removal and resources stay in ArkTS; do not retain platform status-bar objects in Rust.

See the [plugin source](src/main/ets/StatusbarPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
