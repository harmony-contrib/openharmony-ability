# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Add native-tree WebView embedding with Ability-owned, non-reused target IDs.
- Remove native controller declarations before guarded target retirement; retain ArkTS
  owners when retirement fails and await outstanding page tasks before disposal.
- Defer early SDK controller callbacks until explicit native attachment succeeds and
  its UI-thread attach guard has returned.
- Remove the unreleased native generation and unused document-options action (AB6/AB7/AB11).
- Wire production native-embedding regression tests into pull-request CI.

## [1.0.0-beta.3]

- Add optional `domStorageAccess` to the named `ohos.webview.CreateRequest` contract and apply it
  when constructing ArkWeb content; DOM storage remains disabled when the option is omitted.
- Add document-start initialization scripts, URL/header and HTML loading, bounds, visibility,
  background, zoom, focus/reload, cookies, user-agent and debugging controls.
- Add HTTPS interception, async custom-protocol integration and rollback, plus named callbacks
  for page lifecycle, drag/drop, new-window requests and window close requests.
- Add PDF creation/printing and print-state callbacks, page snapshots, viewport PNG capture and
  RGBA pixel-color queries; release temporary PixelMaps in the same platform action.
- Harden controller readiness waits, stale-controller rejection and cleanup after failed creation,
  replacement or plugin disposal.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.

## [1.0.0-beta.2]

- **Breaking**: the bridge contract removes `windowKey`; each native module owns one
  `DefaultXComponent`, while multiple WebViews coexist by controller ID. Multiple windows use
  distinct native modules.
- Coordinate the process-global ArkWeb engine across every active native module before first
  initialization; identical scheme declarations remain idempotent across Ability recreation, and
  a later module may join only with schemes already registered process-wide using the same options.
- Keep public WebView IDs module-local while generating a process-unique ArkWeb controller tag;
  protocol and JavaScript proxy installation use the named `{ id, nativeTag }` event. Navigation,
  download and title events also carry the tag internally so a replaced controller's delayed
  callback cannot target its same-ID replacement.
- Clear Rust controller attachment state again on UI/Ability teardown, so closing-state rejection
  of an ArkTS cleanup notification cannot leak a stale tag into the next appearance.
- **Breaking**: remove numeric plugin versions and module filters; each host now selects the
  factory by ID and validates execution mode and required contexts against its Rust registry.

## [1.0.0-beta.1]

- **Breaking**: normalized node mounting — the named-slot model (`BridgeNodeSlot` /
  `BridgeNodeHost` / `slotId`) is gone. WebView `FrameNode`s mount into the module root tree
  (`context.appendChild`, host-owned unique key), full-bleed by default. WebView IDs remain opaque
  business identifiers rather than becoming node keys.
- **Breaking**: `CreateRequest`/`ControllerRequest`/`ScriptRequest`/`CreateResponse` drop
  `slotId`; `CreateRequest` gains optional `parentHandle` (`ohos.node` container handle) so an
  RS-layer node tree can adopt WebViews as children.
- The module root exists before `ui-context-ready`; controller creation is event-driven.
- Business layering is page `Stack` declaration order; `underlay`/`foreground` hosts are gone.

## [1.0.0-beta.0]

- Initial release: typed `ohos.webview` plugin for embedded WebView (create, controller actions, evaluate script).
- Custom URL schemes via `WebviewProtocol::register` (declared before engine initialization) and page JavaScript proxies.
- Synchronous inbound events for navigation intercept, download start/end and title change, delivered through `on_main_thread_event`.
- Requires `ui-context`; mounts the WebView `FrameNode` into a business-owned `BridgeNodeHost` slot.
