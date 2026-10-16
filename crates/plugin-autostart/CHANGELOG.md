# 1.0.0-beta.3

- Introduce the `ohos.autostart` facade for opening the platform startup-management page and
  querying the app's startup status.
- `enable` and `disable` open settings for the user to choose; they do not silently change the
  system setting. Status queries return `false` below API 21.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
