# Unreleased

- **Breaking**: replace the shared `EagerPlugin` wrapper with a session-scoped `LazyPlugin`
  instance; `PluginBase` rejects reuse across modules/sessions.
- Push the manager from Ability-scoped `onInstall`, without requiring a WindowStage or component.
- **Breaking**: move the native manager from a cross-module global into the registered Rust
  `ResourceBridgePlugin` instance.

---

# 1.0.0-beta.0
- Initial release: inbound-only `ohos.resource` plugin wrapping the native `ResourceManager`.
- ArkTS wrapper pushes the resource manager on `ability-create` through a scoped native event; no outbound actions.
- Uses `EagerPlugin` to share one process-wide wrapper instance.

---
