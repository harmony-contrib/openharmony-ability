# 1.0.0-beta.1

- **Breaking**: normalized node mounting — the named-slot model (`BridgeNodeSlot` /
  `BridgeNodeHost` / `slotId`) is gone. WebView `FrameNode`s mount into the session root tree
  (`context.appendChild`, key `ohos.webview.<id>`), full-bleed by default.
- **Breaking**: `CreateRequest`/`ControllerRequest`/`ScriptRequest`/`CreateResponse` drop
  `slotId`; `CreateRequest` gains optional `parentHandle` (`ohos.node` container handle) so an
  RS-layer node tree can adopt WebViews as children.
- No readiness waiting: the session root exists before `ui-context-ready`; `onInstall` can mount.
- Business layering is page `Stack` declaration order; `underlay`/`foreground` hosts are gone.

--- 
# 1.0.0-beta.0

- Pluginized bridge: typed `BridgePlugin` contract (async / main-thread sync), `BridgeRuntime` / `BridgeMainThread` capabilities, named N-API values only (no JSON transport).
- Support worker-originated synchronous plugin calls through TSFN (`BridgeRuntime::call_sync_from_worker`).
- Add `EagerPlugin` / `LazyPlugin` factory model and attach the inbound event sink at ability create.
- Pluginize platform capabilities: app-control, files, permission, resource, url, webview, window.
- Fix WebView controller references released safely on dispose / last clone drop.

---

# 0.4.0-beta.7

- Fix onBackPressIntercept ran failed.

---

# 0.4.0-beta.6

- Support embedded webview

---

# 0.4.0-beta.5

- Add ResourceManager when init

---

# 0.4.0-beta.4

- Fix onBackPress trigger logic

---

# 0.4.0-beta.3

- Add avoidArea event
- Add onBackPress event

---

# 0.4.0-beta.2

- Support requestPermission method

---

# 0.4.0-beta.1

- Fix gesture for XComponent

---

# 0.4.0-beta.0

- Support non-full mode render.
- Add `oxc-ark` to format code.

---

# 0.3.0

- Allow render xcomponent and webview at the same time.
- Add sync method to load dynamic library.

---

# 0.2.2

- Fix: allow enable devtools

---

# 0.2.1

- Allow load page with html string.
- Allow load url with custom headers.

---

# 0.2.0

- Support webview render mode.

---

# 0.1.5-beta.0

- Add Webview render mode.

---

# 0.1.2

- Use XComponent's `on_frame` to replace `onFrame` callback.

---

# 0.1.1

- Revert: Use `native soloist` to replace `onFrame` callback.

---

# 0.1.0

- Use `native soloist` to replace `onFrame` callback.

---

# 0.0.2

- Allow use custom page or route
- Move default xcomponent to a single component

---

# 0.0.1

- init package
