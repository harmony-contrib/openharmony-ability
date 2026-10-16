# 1.0.0-beta.3

- Introduce the `ohos.system-state` async plugin for thermal level, bundle directory,
  available display area and display snapshots.
- Subscribe to thermal, screen/sleep, available-area and display changes and forward named
  events; clean up listeners/subscribers on disposal.
- Use the hyphenated `ohos.system-state` ID and type-name namespace consistently.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
