# 1.0.0-beta.3

- Introduce the `ohos.autostart` async plugin for navigating to startup-management settings
  and querying this app's status.
- Both enable/disable requests open system settings for user choice; status queries are
  guarded for API 21 and return `false` on older systems.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
