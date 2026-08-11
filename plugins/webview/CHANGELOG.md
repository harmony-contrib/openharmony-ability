# 1.0.0-beta.1

- **Breaking**: the bridge contract removes `windowKey`; each native module owns one
  `DefaultXComponent`, while multiple WebViews coexist by controller ID. Multiple windows use
  distinct native modules.
- **Breaking**: normalized node mounting — the named-slot model (`BridgeNodeSlot` /
  `BridgeNodeHost` / `slotId`) is gone. WebView `FrameNode`s mount into the module root tree
  (`context.appendChild`, host-owned unique key), full-bleed by default. WebView IDs remain opaque
  business identifiers rather than becoming node keys.
- **Breaking**: `CreateRequest`/`ControllerRequest`/`ScriptRequest`/`CreateResponse` drop
  `slotId`; `CreateRequest` gains optional `parentHandle` (`ohos.node` container handle) so an
  RS-layer node tree can adopt WebViews as children.
- The module root exists before `ui-context-ready`; controller creation is event-driven.
- Coordinate the process-global ArkWeb engine across every active native module before first
  initialization; identical scheme declarations remain idempotent across Ability recreation, and
  a later module may join only with schemes already registered process-wide using the same options.
- Keep public WebView IDs module-local while generating a process-unique ArkWeb controller tag;
  protocol and JavaScript proxy installation use the named `{ id, nativeTag }` event. Navigation,
  download and title events also carry the tag internally so a replaced controller's delayed
  callback cannot target its same-ID replacement.
- Clear Rust controller attachment state again on UI/Ability teardown, so closing-state rejection
  of an ArkTS cleanup notification cannot leak a stale tag into the next appearance.
- Business layering is page `Stack` declaration order; `underlay`/`foreground` hosts are gone.

# 1.0.0-beta.0

- Initial release: typed `ohos.webview` plugin for embedded WebView (create, controller actions, evaluate script).
- Custom URL schemes via `WebviewProtocol::register` (declared before engine initialization) and page JavaScript proxies.
- Synchronous inbound events for navigation intercept, download start/end and title change, delivered through `on_main_thread_event`.
- Requires `ui-context`; mounts the WebView `FrameNode` into a business-owned `BridgeNodeHost` slot.

---
