# Unreleased

- Add the named `set-status-bar` action for API 12, preserving navigation-bar settings
  and awaiting native completion before acknowledgement.
- Run status-bar targeting, validation, completion, cancellation and platform-failure
  regression tests in PR CI.
- Add demo controls for light/dark content, omitted background and transparency with
  native status/navigation color checks.

# 1.0.0-beta.3

- Expand window creation/control for desktop and mobile, including display selection,
  decoration/transparency, geometry/limits, fullscreen, focus, visibility and window state.
- Add title/topmost/attention, IME placement, draggable/keep-screen-on, cursor and platform
  window-ID operations with runtime guards for newer APIs.
- Add cancellable prompts positioned in window-content vp coordinates, display-filtered
  stacking queries, RGBA custom cursors and window icons.
- Await platform mutations and bind operations/listeners to the component's actual window.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.

---

# 1.0.0-beta.1

- **Breaking**: all window actions now use the async bridge so Promise-based platform window
  operations are awaited before Rust observes completion.
- Adds host-scoped multi-window create, state and mutation actions; every plugin instance owns and
  disposes its own platform windows without module-aware configuration.
- **Breaking**: the plugin now requires `ui-context` and resolves the Window that owns this
  module's `DefaultXComponent`, so sub-window modules no longer query the Ability's main window.
- **Breaking**: remove the numeric plugin version and module filters; each host now selects the
  factory by ID and validates execution mode and required contexts against its Rust registry.

---

# 1.0.0-beta.0

- Initial release: typed `ohos.window` plugin for window avoid-area queries.
- Main-thread sync `get-avoid-area` action returning the complete avoid area.
- Requires `window-stage` context; callable from the active N-API `Env` via `with_main_thread_bridge(...).call_sync`.

---
