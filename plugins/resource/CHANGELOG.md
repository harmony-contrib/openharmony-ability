# Unreleased

- **Breaking**: replace the shared `EagerPlugin` wrapper with a session-scoped `LazyPlugin`
  instance; Rust continues to own the process-wide native manager pointer.

---

# 1.0.0-beta.0
- Initial release: inbound-only `ohos.resource` plugin wrapping the native `ResourceManager`.
- ArkTS wrapper pushes the resource manager on `ability-create` through a scoped native event; no outbound actions.
- Uses `EagerPlugin` to share one process-wide wrapper instance.

---
