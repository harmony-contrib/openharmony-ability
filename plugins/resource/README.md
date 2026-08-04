# @ohos-rs/plugin-resource

`@ohos-rs/plugin-resource` 是 HarmonyOS `resourceManager` 的 ArkTS wrapper 插件，与 Rust crate
`openharmony-ability-plugin-resource` 成对使用。

## 职责

- 持有 `abilityContext.resourceManager` 平台对象；
- 在 `ui-context-ready` 时经 `context.invokeNativeSync("resource-manager-ready", ...)` 把对象
  推送给 Rust facade；
- 不执行任何资源读取逻辑 —— 所有读取由 Rust 侧通过 `ohos-resource-manager-binding` 直连
  OpenHarmony C API 完成。

## 接入

```ts
import { EagerPlugin } from "@ohos-rs/ability";
import { ResourcePlugin } from "@ohos-rs/plugin-resource";

// in NativeAbility subclass:
public bridgePlugins = [
  new EagerPlugin(new ResourcePlugin()),
];
```

使用 `EagerPlugin`（共享单例实例）而非 `LazyPlugin`：native resource manager 是进程级全局状态，
每个 session 创建独立 wrapper 实例是冗余的。wrapper 被重复 `attachContext` 时只是重复推送同一
对象，天然幂等。

## 契约

| 项目 | 值 |
| --- | --- |
| 插件 ID / 版本 | `ohos.resource` / `1` |
| 执行模式 | `async`（无出站 action，`invokeAsync` 一律抛错） |
| requires | `["ability"]`（与 Rust `REQUIRED_CONTEXTS` 一致） |
| 入站事件 | `resource-manager-ready`：request type `ohos.resource.ResourceManagerRef`，response type `ohos.resource.ResourceManagerReadyResponse` |

## 时序

推送点在 `ability-create`。入站事件 sink 在 `NativeAbility.onCreate` 中 `module.init` 之后立即
attach（`attachBridgeEventSink`），不再等到 UI 渲染；`DefaultXComponent.aboutToAppear` 中的
attach 保留为同一 module 对象的幂等兜底。
