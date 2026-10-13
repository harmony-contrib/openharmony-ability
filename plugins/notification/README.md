# Notification plugin

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
