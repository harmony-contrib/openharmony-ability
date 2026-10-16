# @ohos-rs/ability-plugin-permission

English | [简体中文](README.zh-CN.md)

This is the ArkTS implementation of `openharmony-ability-plugin-permission`. It invokes `abilityAccessCtrl.requestPermissionsFromUser` on the owning Ability context. Application code uses the Rust facade rather than calling internal HAR actions.

## Install

```bash
ohpm install @ohos-rs/ability-plugin-permission
```

## Assembly

Add the HAR to the application's `oh-package.json5`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-permission": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { PermissionPlugin } from "@ohos-rs/ability-plugin-permission";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new PermissionPlugin())];
}
```

Register `PermissionBridgePlugin` in the Rust `#[ability]` initializer. Explicitly install a fresh ArkTS instance and preserve the `NativeAbility` lifecycle call chain. See the [Rust facade README](../../crates/plugin-permission/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.permission` |
| `execution` | `async` |
| `requires` | `["ability"]` |
| Actions | `request` |
| request → response | `ohos.permission.PermissionRequest` → `ohos.permission.PermissionResponse` |

`PermissionPlugin` activates only once its Ability context is available. It validates `payload.typeName`, a non-empty permission array and individual names before invoking the platform; undeclared actions and JSON payloads are rejected.

## Behavior

- `permissions` and returned `codes` preserve the same input order.
- Failed system calls, missing results and fallback unauthorized entries use `-1`, preserving one result per permission.
- After completion, `context.isActive()` rejects calls for a destroyed Ability instead of returning stale results.
- Declare permissions in the application manifest; runtime requests do not replace this configuration.

## Maintenance

Update the Rust crate, ArkTS implementation, tests and demo together when changing actions,
fields or type names. Use new actions/type names for incompatible contracts.
Requests/responses use real N-API objects; do not introduce `JSON.stringify` or `JSON.parse`.

See the [plugin development standard](../../docs/plugin-development-standard.md) for threading,
lifecycle and contract acceptance rules.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
