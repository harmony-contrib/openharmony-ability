# @ohos-rs/ability-plugin-resource

`@ohos-rs/ability-plugin-resource` 是 HarmonyOS `resourceManager` 的 ArkTS wrapper 插件，与 Rust crate
`openharmony-ability-plugin-resource` 成对使用。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-resource
```

## 职责

- 持有 `abilityContext.resourceManager` 平台对象；
- 在 Ability-scoped `onInstall` 经 `context.invokeNativeSync("resource-manager-ready", ...)` 把对象
  推送给 Rust facade；
- 不执行任何资源读取逻辑 —— 所有读取由 Rust 侧通过 `ohos-resource-manager-binding` 直连
  OpenHarmony C API 完成。

## 接入

```ts
import { LazyPlugin } from "@ohos-rs/ability";
import { ResourcePlugin } from "@ohos-rs/ability-plugin-resource";

// in NativeAbility subclass:
public bridgePlugins = [
  new LazyPlugin(() => new ResourcePlugin()),
];
```

ArkTS wrapper 必须是 Host/session 级实例；`attachContext` 会拒绝跨 Host/session 复用。
native resource manager 由匹配的 Rust `ResourceBridgePlugin` registry instance 持有，不共享 ArkTS
plugin instance，也不使用进程级全局 pointer。

## 契约

| 项目 | 值 |
| --- | --- |
| 插件 ID | `ohos.resource` |
| 执行模式 | `async`（无出站 action，`invokeAsync` 一律抛错） |
| requires | `["ability"]`（与 Rust `REQUIRED_CONTEXTS` 一致） |
| 入站事件 | `resource-manager-ready`：request type `ohos.resource.ResourceManagerRef`，response type `ohos.resource.ResourceManagerReadyResponse` |

## 时序

推送点在 `onInstall`。此时入站事件 sink 和 Rust `AbilityCreated` 都已就绪，但不需要 WindowStage、
UIContext 或 DefaultXComponent。
