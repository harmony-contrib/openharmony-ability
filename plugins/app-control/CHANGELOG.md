# 1.0.0-beta.1

- **Breaking**: remove the numeric plugin version and module selection from the ArkTS contract;
  the host now matches this plugin by ID and validates its execution mode and required contexts
  against the Rust registry declaration.
- Plugin instances are session-scoped and cannot be reused across modules or Ability sessions.

---

# 1.0.0-beta.0

- Initial release: typed `ohos.app-control` plugin with a main-thread sync `terminate` action.
- Requires `ability` context; callable from the active N-API `Env` via `with_main_thread_bridge(...).call_sync`.

---
