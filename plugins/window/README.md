# @ohos-rs/ability-plugin-window

这是窗口避让区能力的 ArkTS HAR，对应 Rust crate `openharmony-ability-plugin-window`。它在当前
`WindowStage` 的主窗口上同步调用 `getWindowAvoidArea`，并将完整结果返回 Rust。

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
import { NativeAbility } from "@ohos-rs/ability";
import { createWindowPlugin } from "@ohos-rs/ability-plugin-window";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [createWindowPlugin()];
}
```

Rust 侧还需注册 `WindowBridgePlugin`，并通过当前 N-API callback 的 `Env` 调用
`WindowExt::query_avoid_area`。使用示例见
[Rust facade README](../../crates/plugin-window/README.md)。

## Factory 契约

| 字段 | 值 |
| --- | --- |
| `id` / `version` | `ohos.window` / `1` |
| `execution` | `sync-main-thread` |
| `requires` | `["window-stage"]` |
| 支持 action | `get-avoid-area` |
| request → response | `ohos.window.AvoidAreaRequest` → `ohos.window.AvoidAreaResponse` |

ArkTS request 是 `{ areaType: number }`，response 是
`{ area: { visible, leftRect, topRect, rightRect, bottomRect } }`；每个 rect 都包含
`top`、`left`、`width`、`height`。不能省略任一边的避让区。

## 运行限制

- 必须在 `NativeAbility.onWindowStageCreate` 后才会激活；同步调用不等待 `WindowStage`。
- `invokeSync` 通过 `context.getWindowStage().getMainWindowSync()` 获取主窗口。取主窗口或查询平台 API
  失败时，抛出明确错误给 Rust。
- `areaType` 必须是整数，且 request/response typeName 必须精确匹配；不支持 JSON 或动态对象兼容层。
- 该插件不保存 `WindowStage`、`UIContext` 或 N-API object 到 worker。

完整线程、生命周期和契约变更规则见
[插件开发规范](../../docs/plugin-development-standard.md)。
