# 1.0.0-beta.1

- **Breaking**: normalized node mounting — the named-slot model (`BridgeNodeSlot` /
  `BridgeNodeHost` / `slotId`) is gone. WebView `FrameNode`s mount into the session root tree
  (`context.appendChild`, key `ohos.webview.<id>`), full-bleed by default.
- **Breaking**: `CreateRequest`/`ControllerRequest`/`ScriptRequest`/`CreateResponse` drop
  `slotId`; `CreateRequest` gains optional `parentHandle` (`ohos.node` container handle) so an
  RS-layer node tree can adopt WebViews as children.
- No readiness waiting: the session root exists before `ui-context-ready`; `onInstall` can mount.
- Business layering is page `Stack` declaration order; `underlay`/`foreground` hosts are gone.

# 1.0.0-beta.0

- Initial release: typed `ohos.webview` plugin for embedded WebView (create, controller actions, evaluate script).
- Custom URL schemes via `WebviewProtocol::register` (declared before engine initialization) and page JavaScript proxies.
- Synchronous inbound events for navigation intercept, download start/end and title change, delivered through `on_main_thread_event`.
- Requires `ui-context`; mounts the WebView `FrameNode` into a business-owned `BridgeNodeHost` slot.

---
