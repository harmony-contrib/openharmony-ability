# 1.0.0-beta.1

- **Breaking**: remove `EagerPlugin`; every ArkTS plugin instance is now scoped to one
  module/session, and `PluginBase` rejects instance reuse. Module-owned resources stay in the
  corresponding registered Rust plugin instance.
- **Breaking**: plugin hooks receive `BridgePluginHookContext` with cancellation, and native
  `render(slot, renderOwner)` receives a per-appearance owner plus `disposeRender` cleanup.
- **Breaking**: generic bridge bindings move from component `render` to
  `init(bindings, bridgeOwner, context)` / `disposeBridge(bridgeOwner)`. The transport now follows
  the module's Ability session, so ability-only plugins do not depend on XComponent appearance.
- Propagate `renderOwner` through Rust XComponent surface/input/frame callbacks so stale native
  callbacks cannot mutate a replacement component's window, IME or geometry state.
- Serialize Ability/WindowStage/UI lifecycle with generation guards, bounded hook watchdogs and
  prepare-then-activate startup so Rust sinks exist before ability plugin installation.
- **Breaking**: enforce one `DefaultXComponent` per native module. One Ability supports multiple
  components/windows through distinct modules; the same module cannot belong to two active
  Ability sessions. Duplicate/empty `moduleName` entries fail configuration immediately, and the
  generated native `render` export also rejects a second concurrent root.
- **Breaking**: normalized node mounting — the named-slot model (`BridgeNodeSlot` /
  `BridgeNodeHost` / `slotId`) is gone. WebView `FrameNode`s mount into the module root tree
  (`context.appendChild`, host-owned unique key), full-bleed by default.
- **Breaking**: `CreateRequest`/`ControllerRequest`/`ScriptRequest`/`CreateResponse` drop
  `slotId`; `CreateRequest` gains optional `parentHandle` (`ohos.node` container handle) so an
  RS-layer node tree can adopt WebViews as children.
- **Breaking**: remove `windowKey`/`windowScope` and the `window_key` fields from `ohos.node` and
  WebView create contracts. Multiple WebViews use distinct IDs in
  the same module/component.
- **Breaking**: `BridgePluginContext.getWindow()` resolves the Window that owns the current
  module/component. `ohos.window` now requires `ui-context`, so sub-window queries no
  longer fall back to the Ability's main window.
- Route size/rect/avoid-area/keyboard callbacks from each component's actual Window to only its
  native module; only `windowStageEvent` remains Ability-wide.
- The module/component root exists before `ui-context-ready`; `onInstall` can mount.
- Add named `invokeNativeSyncProcessWide` for process-global plugin transitions; ArkWeb engine
  initialization uses it to coordinate all active plugin facades before the first WebView.
- **Breaking**: remove numeric plugin versions and module filters from the public plugin contract.
  Rust registries export `{ id, execution, requires }`; each Host automatically selects and
  validates the matching ArkTS factory.
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
