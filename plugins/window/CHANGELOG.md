# Unreleased
- **Breaking**: all window actions now use the async bridge so Promise-based platform window
  operations are awaited before Rust observes completion.
- Adds host-scoped multi-window create, state and mutation actions; every plugin instance owns and
  disposes its own platform windows without module-aware configuration.

---

# 1.0.0-beta.1
- **Breaking**: the plugin now requires `ui-context` and resolves the Window that owns this
  module's `DefaultXComponent`, so sub-window modules no longer query the Ability's main window.

---

# 1.0.0-beta.0
- Initial release: typed `ohos.window` plugin for window avoid-area queries.
- Main-thread sync `get-avoid-area` action returning the complete avoid area.
- Requires `window-stage` context; callable from the active N-API `Env` via `with_main_thread_bridge(...).call_sync`.

---
