# openharmony-ability-plugin-app-control

English | [简体中文](README.zh-CN.md)

`openharmony-ability-plugin-app-control` provides application control through a Rust facade.
Its `terminate` operation exits with a supplied code. Use it with the
`@ohos-rs/ability-plugin-app-control` HAR; it is a strictly synchronous main-thread plugin.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-app-control` |
| ArkTS HAR | `@ohos-rs/ability-plugin-app-control` |
| Plugin ID | `ohos.app-control` |
| Execution | `MainThreadSyncBridge` / `invokeSync` |
| Required context | `ability` |
| action | `terminate` |
| request → response | `ohos.app_control.TerminateRequest { code }` → `ohos.app_control.TerminateResponse { accepted }` |

## Integration

Register the Rust facade and ArkTS factory during application startup:

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_app_control::AppControlBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(AppControlBridgePlugin)
        .expect("app-control facade must be registered once");
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AppControlPlugin } from "@ohos-rs/ability-plugin-app-control";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AppControlPlugin())];
}
```

Add `@ohos-rs/ability-plugin-app-control` to the application's `oh-package.json5`.
See the [ArkTS README](../../plugins/app-control/README.md) for HAR dependencies and setup.

## Rust usage

Call `AppControlExt::terminate` only from an exported N-API callback, passing the callback's
current `Env`:

```rust
use napi_ohos::{Env, Result};
use openharmony_ability_plugin_app_control::AppControlExt;

#[napi]
pub fn terminate_application(env: Env, code: i32) -> Result<()> {
    current_app()?.terminate(&env, code)
}
```

`current_app()` represents the application's saved `OpenHarmonyApp` from `#[ability]`
initialization. Obtain `Env` from the current N-API callback; do not cache, clone or move it
between threads.

## Threading and lifecycle constraints

- This is a sync API. Do not call it from a Rust worker, async future, spawned task or `block_on`.
- `BridgeMainThread` validates the active N-API environment. Session initialization opens the
  transport independently of `DefaultXComponent`. An unavailable Ability, closed session or
  mismatched `Env` fails immediately.
- ArkTS calls `process.ProcessManager.exit(code)`. Do not rely on code continuing after the
  system exits the process.
- The Rust facade converts `accepted = false` into an error.

## Development constraints

The `terminate` request/response are named N-API objects, without JSON or Promise wrappers.
Keep immediately deciding operations in `MainThreadSyncBridge`; define separate async actions
for async capabilities rather than blocking on them.

See the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
