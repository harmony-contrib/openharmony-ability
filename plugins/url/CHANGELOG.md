# 1.0.0-beta.3

- Add `check-scheme` to inspect this Ability's installed manifest declarations; URL schemes
  remain installation-time configuration.
- Add `open-file` for file URIs and `reveal-in-dir` for absolute directories through system
  file-manager integration.
- Accept valid non-hierarchical URLs and preserve named request/response validation.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.

---

# 1.0.0-beta.1

- **Breaking**: remove the numeric plugin version and module selection from the ArkTS contract;
  the host now matches this plugin by ID and validates its execution mode and required contexts
  against the Rust registry declaration.
- Plugin instances are session-scoped and cannot be reused across modules or Ability sessions.

---

# 1.0.0-beta.0

- Initial release: typed `ohos.url` plugin for opening external URLs via `context.openLink`.
- Requires `ability` context; async action callable from any Rust thread.

---
