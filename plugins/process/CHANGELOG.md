# 1.0.0-beta.3

- Introduce the `ohos.process` async plugin for platform-managed application restart using
  `appRecovery`.
- Validate named restart requests and use lifecycle-safe plugin registration; restart may
  terminate the process without an Ability destroy callback.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
