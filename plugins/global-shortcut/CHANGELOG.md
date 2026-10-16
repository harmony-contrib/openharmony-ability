# 1.0.0-beta.3

- Introduce the `ohos.global-shortcut` async plugin backed by platform hotkey subscriptions.
- Add register, unregister and unregister-all actions plus named shortcut-triggered callbacks.
- Guard hotkey registration for API 14 and release subscriptions on plugin disposal.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
