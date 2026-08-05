# 1.0.0-beta.0
- Initial release: typed `ohos.webview` plugin for embedded WebView (create, controller actions, evaluate script).
- Custom URL schemes via `WebviewProtocol::register` (declared before engine initialization) and page JavaScript proxies.
- Synchronous inbound events for navigation intercept, download start/end and title change, delivered through `on_main_thread_event`.
- Requires `ui-context`; mounts the WebView `FrameNode` into a business-owned `BridgeNodeHost` slot.

---
