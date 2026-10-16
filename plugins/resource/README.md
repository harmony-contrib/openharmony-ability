# @ohos-rs/ability-plugin-resource

English | [简体中文](README.zh-CN.md)

`@ohos-rs/ability-plugin-resource` is the ArkTS resource-manager wrapper paired with
`openharmony-ability-plugin-resource`.

## Install

```bash
ohpm install @ohos-rs/ability-plugin-resource
```

## Responsibilities

- Own `abilityContext.resourceManager`.
- Push it to Rust during Ability-scoped `onInstall` through
  `context.invokeNativeSync("resource-manager-ready", ...)`.
- Leave all reads to Rust, which calls the OpenHarmony C API through
  `ohos-resource-manager-binding`.

## Integration

```ts
import { LazyPlugin } from "@ohos-rs/ability";
import { ResourcePlugin } from "@ohos-rs/ability-plugin-resource";

// in NativeAbility subclass:
public bridgePlugins = [
  new LazyPlugin(() => new ResourcePlugin()),
];
```

Use a separate wrapper instance for each host/session. `attachContext` rejects reuse across
hosts/sessions. The matching Rust `ResourceBridgePlugin` registry instance owns the native
manager; do not share ArkTS instances or use a process-global pointer.

## Contract

| Field | Value |
| --- | --- |
| Plugin ID | `ohos.resource` |
| Execution | `async` (no outbound actions; `invokeAsync` always throws) |
| requires | `["ability"]`, matching Rust `REQUIRED_CONTEXTS` |
| Inbound event | `resource-manager-ready`: `ohos.resource.ResourceManagerRef` → `ohos.resource.ResourceManagerReadyResponse` |

## Timing

The push occurs in `onInstall`, after the inbound event sink and Rust `AbilityCreated` are ready.
It does not require WindowStage, UIContext or DefaultXComponent.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
