# openharmony-ability-plugin-account

English | [简体中文](README.zh-CN.md)

Use Huawei Account Kit for interactive login, silent login and revoking application authorization.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-account` |
| ArkTS HAR | `@ohos-rs/ability-plugin-account` |
| Plugin ID | `ohos.account` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ability"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-account = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_account::AccountBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(AccountBridgePlugin)
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AccountPlugin } from "@ohos-rs/ability-plugin-account";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AccountPlugin())];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/account/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_account::{AccountExt, AccountInfo};

async fn login(app: &OpenHarmonyApp) -> Result<AccountInfo> {
    app.account()?.login().await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `login` | `login` | Show the login panel and return AccountInfo. |
| `silent_login` | `silentLogin` | Log in without showing a panel. |
| `logout` | `logout` | Revoke this application's Huawei Account authorization. |

## Behavior and lifecycle

- The target device and application must support Huawei Account Kit. Configure the application's account service separately.
- Interactive login allows five minutes for user verification. Silent login shows no UI and can fail when device login or application authorization requirements are not met.
- `AccountInfo` contains `uid`, `open_id`, `union_id`, `display_name`, `avatar_uri`, `authorization_code` and optional `access_token`. String fields may be empty when omitted by the platform.
- `logout` revokes application authorization; it does not sign the device out of its system account. The bridge action retains its existing ABI spelling, `silentLogin`.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
