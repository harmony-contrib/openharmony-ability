# 1.0.0-beta.3

- Introduce the `ohos.menu` async facade for window menu bars, popup menus, visibility and
  predefined actions.
- Deliver menu-click and menu-open events through injected Rust senders; cache menu content
  and visibility only after successful bridge calls.
- Pair with dropdown state fixes, separator and shortcut-label rendering, and modifier-aware
  accelerator matching in the ArkTS implementation.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
