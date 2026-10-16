# Changelog

## 1.0.0-beta.3

All 24 Rust crates and 21 ArkTS HAR packages now share `1.0.0-beta.3`.
Package changelogs below contain capability-specific notes and existing release history.

### Runtime and platform integration

- Add desktop/mobile multi-window support, native Float-window pages, display selection and
  window attachment tracking. Route native surfaces, input, redraw, resize, focus and close
  events by window ID, with per-window geometry, avoid areas and IME state.
- **Breaking**: Rust `Event::WindowResize` changes to `{ window_id, size }`. Update event matches
  and handle the new sub-window event variants when integrating an application event loop.
- Extend `#[ability]` with sub-window rendering/close exports and initialize SDK/distribution API
  versions before application setup. Add a process initializer shared by Rust and C/SDL modules.
- Add opt-in ArkUI keyboard snapshots/key consumption, mouse cancellation, stylus and native
  file drag/drop features. Add cursor-grab helpers and improve IME, wake and frame delivery.
- Deliver launch URIs, Want parameters and continuation state through the app session; support
  source-side continuation snapshots and target-side cold/warm window-stage restoration.
- Add generic host dispatch hooks for optional interception plugins. Interactive bridge calls
  can opt into a five-minute timeout; ordinary calls retain the 15-second default.

### Plugins

- Add accessibility, Huawei Account, startup settings, clipboard, deep-link, fault-injection,
  global-shortcut, menu, notification, process, status-bar, system-state and AppGallery updater
  packages, plus Rust continuation and screenshot facades.
- Expand WebView support with DOM storage, initialization scripts, URL/header/HTML loading,
  controller settings, HTTPS interception, async custom protocols, page/drag/window callbacks,
  PDF generation/printing, snapshots, viewport capture and pixel-color queries.
- Expand window control with decorations, transparency, focus/fullscreen, geometry/limits,
  state/title/topmost/attention, IME and cursor operations, anchored prompts, stacking queries
  and RGBA custom cursors/window icons.
- Add Ability hide/show and application color-mode control, suggested save-file names, installed
  URL-scheme checks, file opening and directory reveal.
- **Configuration**: clipboard factories require an application-specific `metadataMimeType`;
  notification factories require the application's response `scheme`. Keep these values in
  the application's factory configuration.
- Startup enable/disable requests open system settings for user choice. Screenshot delegates
  to the WebView plugin; continuation uses core lifecycle state and needs no separate HAR.

### Fixes

- Release render callbacks and gestures before disposing ArkUI roots, including sub-window roots.
- Resolve the event-loop waker at wake time so proxies created before lifecycle initialization
  can deliver worker-thread events once setup completes.
- Preserve menu dropdown state and refresh menus on opening; render separators/shortcut labels
  and match accelerators with the correct modifiers.
- Allow folder selection on capable devices without a 2-in-1 allowlist, retain API guards for
  selected-filter queries and include platform details in file-dialog errors.
- Defer platform color-mode changes to avoid reentrant configuration-update deadlocks.
- Harden WebView controller readiness, callback identity checks and cleanup across failed
  creation, replacement and plugin disposal; release temporary snapshot image resources.
- Use the consistent `ohos.system-state` plugin ID/type-name namespace and clean up platform
  event subscriptions with their owning session.

### Workspace and development commands

- Centralize Rust package version, edition `2021` and license `MIT OR Apache-2.0` in
  `workspace.package`; use workspace-managed versions for internal Cargo dependencies.
- Align ArkTS package versions and switch internal HAR dependencies to `workspace:*` through
  `ohpm-workspace.yaml`, including the demo's source-package dependencies.
- Use `ohpm-rs pack --workspace --output dist` through `npm run pack`; remove the duplicate
  shell, batch and PowerShell packaging wrappers.
- Install `ohpm-cli` 0.3.0 during dependency setup and use the Node `install:ohpm` wrapper for
  workspace/demo dependency installation.
- Keep `npm run format` for manual formatting and prek for hooks/checks; remove the separate
  format-check and runtime-regression scripts. CI invokes `npm run prek -- --all-files` and
  `npm run lint:rs` for the supported OHOS targets.

### Package changelogs

| Component | Rust | ArkTS |
| --- | --- | --- |
| Core runtime | [crate](crates/ability/CHANGELOG.md) | [@ohos-rs/ability](native_ability/CHANGELOG.md) |
| Entry macro | [crate](crates/derive/CHANGELOG.md) | — |
| accessibility | [crate](crates/plugin-accessibility/CHANGELOG.md) | [HAR](plugins/accessibility/CHANGELOG.md) |
| account | [crate](crates/plugin-account/CHANGELOG.md) | [HAR](plugins/account/CHANGELOG.md) |
| app-control | [crate](crates/plugin-app-control/CHANGELOG.md) | [HAR](plugins/app-control/CHANGELOG.md) |
| autostart | [crate](crates/plugin-autostart/CHANGELOG.md) | [HAR](plugins/autostart/CHANGELOG.md) |
| clipboard | [crate](crates/plugin-clipboard/CHANGELOG.md) | [HAR](plugins/clipboard/CHANGELOG.md) |
| continuation | [crate](crates/plugin-continuation/CHANGELOG.md) | Core lifecycle facade |
| deep-link | [crate](crates/plugin-deep-link/CHANGELOG.md) | [HAR](plugins/deep-link/CHANGELOG.md) |
| fault-injection | [crate](crates/plugin-fault-injection/CHANGELOG.md) | [HAR](plugins/faultinjection/CHANGELOG.md) |
| files | [crate](crates/plugin-files/CHANGELOG.md) | [HAR](plugins/files/CHANGELOG.md) |
| global-shortcut | [crate](crates/plugin-global-shortcut/CHANGELOG.md) | [HAR](plugins/global-shortcut/CHANGELOG.md) |
| menu | [crate](crates/plugin-menu/CHANGELOG.md) | [HAR](plugins/menu/CHANGELOG.md) |
| notification | [crate](crates/plugin-notification/CHANGELOG.md) | [HAR](plugins/notification/CHANGELOG.md) |
| permission | [crate](crates/plugin-permission/CHANGELOG.md) | [HAR](plugins/permission/CHANGELOG.md) |
| process | [crate](crates/plugin-process/CHANGELOG.md) | [HAR](plugins/process/CHANGELOG.md) |
| resource | [crate](crates/plugin-resource/CHANGELOG.md) | [HAR](plugins/resource/CHANGELOG.md) |
| screenshot | [crate](crates/plugin-screenshot/CHANGELOG.md) | Uses [WebView HAR](plugins/webview/CHANGELOG.md) |
| statusbar | [crate](crates/plugin-statusbar/CHANGELOG.md) | [HAR](plugins/statusbar/CHANGELOG.md) |
| system-state | [crate](crates/plugin-system-state/CHANGELOG.md) | [HAR](plugins/system-state/CHANGELOG.md) |
| updater | [crate](crates/plugin-updater/CHANGELOG.md) | [HAR](plugins/updater/CHANGELOG.md) |
| url | [crate](crates/plugin-url/CHANGELOG.md) | [HAR](plugins/url/CHANGELOG.md) |
| webview | [crate](crates/plugin-webview/CHANGELOG.md) | [HAR](plugins/webview/CHANGELOG.md) |
| window | [crate](crates/plugin-window/CHANGELOG.md) | [HAR](plugins/window/CHANGELOG.md) |
