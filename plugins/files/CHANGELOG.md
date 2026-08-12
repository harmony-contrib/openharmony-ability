# 1.0.0-beta.1

- **Breaking**: remove the numeric plugin version and module selection from the ArkTS contract;
  the host now matches this plugin by ID and validates its execution mode and required contexts
  against the Rust registry declaration.
- Keep API 12 build compatibility while using `getSelectedIndex` only after the existing API 14
  runtime capability check.

---

# 1.0.0-beta.0

- Initial release: typed `ohos.files` plugin for file dialogs (open / save / folder).
- Structured `DialogOptions` transport; filter strings are converted only inside the plugin.
- Requires `ability` context; async actions.

---
