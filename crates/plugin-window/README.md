# openharmony-ability-plugin-window

`openharmony-ability-plugin-window` 是窗口能力的 Rust facade。当前提供同步查询窗口避让区
(`AvoidArea`) 的能力，对应 ArkTS HAR 为 `@ohos-rs/ability-plugin-window`。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-window` |
| ArkTS HAR | `@ohos-rs/ability-plugin-window` |
| 插件 ID / bridge 版本 | `ohos.window` / `2` |
| 执行模式 | 主线程同步：`MainThreadSyncBridge` / `invokeSync` |
| 前置 context | `ui-context` |
| action | `get-avoid-area` |
| request → response | `ohos.window.AvoidAreaRequest` → `ohos.window.AvoidAreaResponse` |

返回的 `AvoidArea` 包含 `visible` 以及 `left_rect`、`top_rect`、`right_rect`、`bottom_rect` 四个矩形；
迁移旧 helper 时不得只保留其中一部分。

## 接入

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

应用还需在 `oh-package.json5` 中添加 `@ohos-rs/ability-plugin-window`。ArkTS factory 的说明见
[对应 HAR README](../../plugins/window/README.md)。

## Rust 使用方式

```rust
use napi_ohos::{Env, Result};
use openharmony_ability::AvoidAreaType;
use openharmony_ability_plugin_window::WindowExt;

#[napi]
pub fn keyboard_insets(env: Env) -> Result<i32> {
    let area = current_app()?.query_avoid_area(&env, AvoidAreaType::Keyboard)?;
    Ok(area.bottom_rect.height)
}
```

`current_app()` 代表应用在 `#[ability]` 初始化时保存并按需读取的 `OpenHarmonyApp`。

`AvoidAreaType` 支持 `System`、`Cutout`、`SystemGesture`、`Keyboard`、`NavigationIndicator` 和
`Unknown(i32)`。实际含义由 HarmonyOS `window.AvoidAreaType` 决定。

## 调用限制

- 查询是同步主线程调用：`Env` 必须来自当前导出的 N-API callback，不能从 worker 保存后使用。
- 当前 module 的 `DefaultXComponent` 必须已经建立 `UIContext`。同步调用不会等待组件出现，未就绪时
  直接失败。
- ArkTS 通过 `context.getWindow()` 获取该组件实际所在窗口，再调用
  `getWindowAvoidArea(areaType)`；因此主窗口和 sub window 会各自返回自己的避让区。
- request/response 为具名 N-API object；Rust `area_type` 会映射为 ArkTS `areaType`，不使用 JSON。

完整的线程、生命周期和契约变更要求见
[插件开发规范](../../docs/plugin-development-standard.md)。
