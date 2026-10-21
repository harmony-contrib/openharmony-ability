# ArkUI plugin

The API-20 `ArkuiPlugin` factory pairs with the [Rust editor facade](../../crates/plugin-arkui/README.md).
Register a fresh factory in NativeAbility. The plugin owns system editors and
retires native edges synchronously in `onClosing`; UI-context detach also
releases every entry independently.
