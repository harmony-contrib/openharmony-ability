# openharmony-ability-plugin-permission

English | [简体中文](README.zh-CN.md)

`openharmony-ability-plugin-permission` is the Rust runtime-permission facade, paired with
`@ohos-rs/ability-plugin-permission`. Rust sends typed async requests; ArkTS uses
`abilityAccessCtrl` to show system authorization UI and return results.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-permission` |
| ArkTS HAR | `@ohos-rs/ability-plugin-permission` |
| Plugin ID | `ohos.permission` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required context | `ability` |
| action | `request` |
| request → response | `ohos.permission.PermissionRequest` → `ohos.permission.PermissionResponse` |

Calls use named N-API objects rather than JSON strings. The Rust/ArkTS field is `permissions`;
returned `codes` match input permission indices.

## Integration

1. Add the crate to the native module and register it in the `#[ability]` initializer:

   ```rust
   use openharmony_ability::OpenHarmonyApp;
   use openharmony_ability_derive::ability;
   use openharmony_ability_plugin_permission::PermissionBridgePlugin;

   #[ability]
   fn configure_ability(app: OpenHarmonyApp) {
       app.register_plugin(PermissionBridgePlugin)
           .expect("permission facade must be registered once");
   }
   ```

2. Add the HAR to `oh-package.json5` and explicitly install a fresh `PermissionPlugin` through
   `LazyPlugin` in the `NativeAbility` subclass:

   ```ts
   import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
   import { PermissionPlugin } from "@ohos-rs/ability-plugin-permission";

   export default class EntryAbility extends NativeAbility {
     public bridgePlugins = [new LazyPlugin(() => new PermissionPlugin())];
   }
   ```

3. Declare the required OpenHarmony permissions in `module.json5`. Runtime requests cannot
   bypass manifest declarations or system authorization policy.

Both sides must be installed; adding only the crate or only the HAR fails at the bridge boundary.

## Rust usage

`PermissionExt` adds `request_permission` to `OpenHarmonyApp`.
It accepts a single `&str`/`String`, `Vec<String>` or `Vec<&str>`, returning
`Vec<PermissionRequestCode>`.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_permission::PermissionExt;

async fn request_camera(app: &OpenHarmonyApp) -> Result<()> {
    let results = app
        .request_permission(vec![
            "ohos.permission.CAMERA",
            "ohos.permission.MICROPHONE",
        ])
        .await?;

    for result in results {
        // result.permission is the requested name; result.code is the system result.
        tracing::info!(permission = %result.permission, code = result.code);
    }
    Ok(())
}
```

The worker-safe async API transfers through TSFN to ArkTS, waits for authorization UI, then
returns owned Rust data. Do not block the ArkTS main thread or add a caller-side `block_on`.

## Behavior and errors

- Empty permission lists or whitespace-only names are rejected before dispatch.
- Rust sets a 60-second bridge deadline. Timeouts and Ability/session destruction cancel waiting.
- ArkTS initializes each result to `-1`. Failed system requests or short result arrays retain
  `-1` for missing entries; result order always matches input order.
- After authorization, ArkTS checks `context.isActive()`. A destroyed Ability returns an error
  rather than stale results.

## Development and troubleshooting

ArkTS checks `typeName === "ohos.permission.PermissionRequest"` and returns
`"ohos.permission.PermissionResponse"`. Update both implementations, tests and demo together
when changing actions/fields. Keep plugin ID, execution and contexts aligned; do not serialize
payloads with JSON APIs.

See the [plugin development standard](../../docs/plugin-development-standard.md) and the
[HAR README](../../plugins/permission/README.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
