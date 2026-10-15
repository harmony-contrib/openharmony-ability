# openharmony-ability-plugin-notification

English | [简体中文](README.zh-CN.md)

Publish and dismiss system notifications, routing clicks through the application's configured URI scheme.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-notification` |
| ArkTS HAR | `@ohos-rs/ability-plugin-notification` |
| Plugin ID | `ohos.notification` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required contexts | `["ability"]` |

## Integration

Add the dependency to an existing `openharmony-ability` application and register the Rust facade in its `#[ability]` initializer:

```toml
[dependencies]
openharmony-ability-plugin-notification = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_notification::NotificationBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(NotificationBridgePlugin)
        .expect("register the plugin once");
}
```

Install the matching HAR and merge the factory into the existing `NativeAbility.bridgePlugins`, retaining the application's native-module and page configuration:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { NotificationPlugin } from "@ohos-rs/ability-plugin-notification";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new NotificationPlugin({ scheme: "my-app-notification" }))];
}
```

See the HAR dependencies and platform implementation in [ArkTS README](../../plugins/notification/README.md).

## Rust usage

Call asynchronous functions from the application's Rust executor/worker. Do not `block_on` a bridge future on the N-API main thread.

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_notification::{NotificationClient, ShowNotificationRequest};

async fn notify(app: &OpenHarmonyApp) -> Result<bool> {
    NotificationClient::new(app)?.show(ShowNotificationRequest {
        tag: "download-complete".to_owned(),
        title: "下载完成".to_owned(),
        body: "文件已保存".to_owned(),
        actions: vec![],
    }).await
}
```

| Rust API | action | Behavior |
| --- | --- | --- |
| `NotificationClient::show` | `show` | Publish a tagged notification with title, body and actions. |
| `NotificationClient::dismiss` | `dismiss` | Dismiss a notification by tag. |

## Behavior and lifecycle

- Construct the client with `NotificationClient::new(app)?`. This crate has no `NotificationExt` trait.
- `tag`, `title` and `body` must be non-empty. At most three actions are allowed; each needs a non-empty `id` and `label`. Publishing returns the platform's `accepted` value.
- The ArkTS factory requires the application's `scheme`; handle its `onNewWant` response. Body/action taps share the response URI format documented in the ArkTS README.
- `show` allows up to two minutes for authorization interaction. Actual display depends on system authorization and runtime conditions.

Clients bind to the bridge session active at construction; obtain a new client after that session closes. See the [Rust source](src/lib.rs) and [plugin development standard](../../docs/plugin-development-standard.md) for complete contracts.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
