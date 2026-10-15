# 1.0.0-beta.3

- Introduce the `ohos.statusbar` async plugin for status-bar items, icons, tooltips, menus and
  predefined actions, with named icon/menu-click callbacks.
- Reuse the menu HAR for menu behavior, matching the Rust crate dependency direction.
- Release platform status-bar resources during plugin disposal.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
