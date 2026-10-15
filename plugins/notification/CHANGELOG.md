# 1.0.0-beta.3

- Introduce the `ohos.notification` async plugin for publishing and cancelling system notifications.
- **Configuration**: require a per-instance application `scheme`; notification-body taps and
  action buttons deliver a response URI to the target Ability's `onNewWant`.
- Allow up to three actions and validate the whole action list before authorization or
  WantAgent creation; keep platform resources and notification work on the ArkTS side.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
