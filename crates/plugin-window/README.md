# openharmony-ability-plugin-window

`openharmony-ability-plugin-window` 是窗口能力的异步 Rust facade，对应 ArkTS HAR
`@ohos-rs/ability-plugin-window`。它既能查询当前 `DefaultXComponent` 所在窗口的避让区，也能创建和
管理多个 OS sub-window。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-window` |
| ArkTS HAR | `@ohos-rs/ability-plugin-window` |
| 插件 ID | `ohos.window` |
| 执行模式 | 异步：`AsyncBridge` / `invokeAsync` |
| 前置 context | `ui-context` |
| 查询 action | `get-avoid-area`、`is-maximized`、`is-minimized` |
| 窗口 action | `create-os-window`、装饰/背景/阴影、焦点、移动/缩放、最小化/最大化/恢复/显示/销毁 |

`AvoidArea` 保留 `visible` 以及 `left_rect`、`top_rect`、`right_rect`、`bottom_rect` 四个矩形；迁移旧
helper 时不得只保留其中一部分。所有 request/response 都是具名 N-API object，不使用 JSON。

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

## Rust 使用方式

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

## 调用与生命周期

- `WindowClient` 只保存 worker-safe `BridgeRuntime`，平台 `Window` 始终留在 ArkTS。
- 插件不读取 native module 名称。每个插件实例维护自己的 platform window id → `Window` 映射；同一
  component 可以创建多个 sub-window，多 Host/plugin instance 的重复调用互不覆盖。
- `ui-context` 未就绪时异步调用由 Host 的 context gate 管理；调用取消或 session 销毁后不会发布过期
  结果。
- `onDispose` 会销毁该插件实例创建的全部 sub-window。未知或已释放的 window id 会确定性失败。
- ArkTS 使用 `context.getWindow()` 查询当前 component 的实际窗口，因此主窗口和 sub window 组件会
  分别得到自己的避让区。

完整规则见[插件开发规范](../../docs/plugin-development-standard.md)。
