# 1.0.0-beta.3

- Extend `#[ability]` exports with `render_window` and `notify_native_window_close` for
  window-specific native roots and close notifications.
- Track sub-window roots separately and release native render state before dropping main or
  sub-window roots, avoiding callbacks and gesture cleanup against freed nodes.
- Initialize SDK/distribution version information from the ArkTS init context before application
  setup, so runtime capability checks see the actual platform version.
- Qualify generated `openharmony_ability` paths to avoid caller-side name shadowing.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
