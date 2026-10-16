# 1.0.0-beta.3

- Add optional `suggestedName` to save-dialog requests and map it to the platform's suggested
  file names; reject it on other dialog types or when empty.
- Let the platform picker determine folder support instead of rejecting non-2-in-1 devices;
  retain the guarded API 14 selected-filter query.
- Check session activity before and after the picker and include device, API and platform
  error details in dialog failures.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.

---

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
