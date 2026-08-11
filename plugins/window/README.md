# @ohos-rs/ability-plugin-window

这是 `openharmony-ability-plugin-window` 的 ArkTS HAR。插件在当前 Host 所绑定
`DefaultXComponent` 的实际窗口上查询避让区，并通过异步平台 API 创建和管理 OS sub-window；实现不
读取 native module 名称。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-window
```

## 装配

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.0",
    "@ohos-rs/ability-plugin-window": "1.0.0-beta.0"
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

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.window` |
| `execution` | `async` |
| `requires` | `["ui-context"]` |
| 查询 action | `get-avoid-area`、`is-maximized`、`is-minimized` |
| 窗口 action | `create-os-window`、装饰/背景/阴影、焦点、移动/缩放、最小化/最大化/恢复/显示/销毁 |

`get-avoid-area` 返回完整的 `{ visible, leftRect, topRect, rightRect, bottomRect }`。创建窗口返回
platform `windowId`，后续操作只按这个业务句柄路由，不按 native module 配置。

## 运行限制

- 当前 Host 的 `DefaultXComponent` 注入 UIContext 后插件才满足 requirements；异步调用由 Host 等待
  context 或响应取消。
- 一个插件实例可同时持有多个 sub-window；窗口 ID 在该实例内查找，`onDispose` 会逐个销毁。
- 创建流程会等待 move、resize、背景/装饰和 show 完成后再返回，任一步失败都会回收已创建窗口。
- `context.getWindow()` 始终解析该 component 的实际窗口，不会把 Ability 主窗口广播给 sub-window
  component。
- request/response typeName 必须精确匹配；不支持 JSON 或动态兼容层。

Rust 侧注册和调用示例见[Rust facade README](../../crates/plugin-window/README.md)，完整规则见
[插件开发规范](../../docs/plugin-development-standard.md)。
