# @ohos-rs/ability-plugin-account

English | [简体中文](README.zh-CN.md)

Use Huawei Account Kit for interactive login, silent login and revoking application authorization.

This is the ArkTS implementation paired with [`openharmony-ability-plugin-account`](../../crates/plugin-account/README.md).

## Install

```bash
ohpm install @ohos-rs/ability-plugin-account
```

## Assembly

Add matching versions to the application's `oh-package.json5`. Internal repository dependencies continue to use `workspace:*`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-account": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AccountPlugin } from "@ohos-rs/ability-plugin-account";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AccountPlugin())];
}
```

Merge the factory into the existing Ability and retain native-module/page configuration. Create a fresh instance for each session; do not reuse it across hosts. Register `AccountBridgePlugin` in the Rust `#[ability]` initializer; see the [Rust facade README](../../crates/plugin-account/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.account` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | Behavior |
| --- | --- | --- |
| `login` | `login` | Show the login panel and return AccountInfo. |
| `silent_login` | `silentLogin` | Log in without showing a panel. |
| `logout` | `logout` | Revoke this application's Huawei Account authorization. |

Call through the Rust facade. The host dispatches named N-API requests/responses; platform objects remain in ArkTS.

## Runtime constraints

- The target device and application must support Huawei Account Kit. Configure the application's account service separately.
- Interactive login allows five minutes for user verification. Silent login shows no UI and can fail when device login or application authorization requirements are not met.
- `AccountInfo` contains `uid`, `open_id`, `union_id`, `display_name`, `avatar_uri`, `authorization_code` and optional `access_token`. String fields may be empty when omitted by the platform.
- `logout` revokes application authorization; it does not sign the device out of its system account. The bridge action retains its existing ABI spelling, `silentLogin`.

See the [plugin source](src/main/ets/AccountPlugin.ets) and the [plugin development standard](../../docs/plugin-development-standard.md).

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
