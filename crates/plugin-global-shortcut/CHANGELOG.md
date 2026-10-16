# 1.0.0-beta.3

- Introduce the `ohos.global-shortcut` facade for registering, unregistering and clearing
  system hotkeys, with a Rust receiver for named shortcut-triggered events.
- Guard registration with the API 14 capability requirement and keep platform listeners
  scoped to the active plugin lifecycle.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
