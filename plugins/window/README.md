# @ohos-rs/ability-plugin-window

这是窗口避让区能力的 ArkTS HAR，对应 Rust crate `openharmony-ability-plugin-window`。它在当前
Host 所绑定 `DefaultXComponent` 的实际窗口上同步调用 `getWindowAvoidArea`，并将完整结果返回 Rust；
插件实现不读取 native module 名称。

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

Rust 侧还需注册 `WindowBridgePlugin`，并通过当前 N-API callback 的 `Env` 调用
`WindowExt::query_avoid_area`。使用示例见
[Rust facade README](../../crates/plugin-window/README.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.window` |
| `execution` | `sync-main-thread` |
| `requires` | `["ui-context"]` |
| 支持 action | `get-avoid-area` |
| request → response | `ohos.window.AvoidAreaRequest` → `ohos.window.AvoidAreaResponse` |

ArkTS request 是 `{ areaType: number }`，response 是
`{ area: { visible, leftRect, topRect, rightRect, bottomRect } }`；每个 rect 都包含
`top`、`left`、`width`、`height`。不能省略任一边的避让区。

## 运行限制

- 当前 Host 的 `DefaultXComponent` 注入 `UIContext` 后才会激活；同步调用不等待组件就绪。
- `invokeSync` 通过 `context.getWindow()` 获取该组件实际所在的主窗口或 sub window。定位窗口或查询
  平台 API 失败时，抛出明确错误给 Rust。
- `areaType` 必须是整数，且 request/response typeName 必须精确匹配；不支持 JSON 或动态对象兼容层。
- 该插件不保存 `WindowStage`、`UIContext` 或 N-API object 到 worker。

完整线程、生命周期和契约变更规则见
[插件开发规范](../../docs/plugin-development-standard.md)。
