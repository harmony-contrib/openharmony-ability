# Notification plugin

English | [简体中文](README.zh-CN.md)

## Install

```bash
ohpm install @ohos-rs/ability-plugin-notification
```

## Assembly

Register a fresh plugin through a factory. The constructor requires an options
object with `scheme`, the application's URI scheme without `:` or `://`:

```ts
import { LazyPlugin } from "@ohos-rs/ability";
import { NotificationPlugin } from "@ohos-rs/ability-plugin-notification";

new LazyPlugin(() => new NotificationPlugin({ scheme: "my-app-notification" }));
```

Notification taps and action buttons deliver
`<scheme>://response?tag=<encoded-tag>&action=<encoded-action-id>` to the target
Ability's `onNewWant`. The action query parameter is absent for a notification-body tap.
Schemes are checked during construction and normalized to lowercase. Each instance
keeps its own configuration, so different Ability factories can use different schemes.
The framework provides no default scheme. Configure the same scheme in the application's
response handler. Existing GPUI integrations can explicitly pass `{ scheme: "gpui-notification" }`.

Notifications accept up to three actions. Rust and ArkTS reject excess actions;
ArkTS validates the whole array before requesting authorization or creating WantAgents.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).

## Toolkit contract additions

`show-with-options` adds grouping, a decoded image, sender display name and the silent content-information slot. System notification preferences still apply. `parse-response` recognizes the configured response URI for cold and warm starts; `dismiss-all` also removes notifications from previous runs. Sender identity/avatar and communication-notification semantics are not synthesized.
