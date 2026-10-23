# Runtime ownership and platform constraints

This document distinguishes platform constraints from the current bridge architecture. A global registry does not make the objects it indexes process-wide resources.

| Resource or policy | Ownership and decision | Evidence |
| --- | --- | --- |
| Menu row, shortcut handling, popup focus, open/click callbacks and predefined actions | Actual window. `MenuPluginOptions` supplies the policy for the windows bound by that plugin instance. Another host may use different options. Ordinary menu events call only the owning native instance. | `MenuPlugin`, `MenuWindowRegistry`, `MenuBarSlot`; [ArkUI menus](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-universal-attributes-menu.md) bind to a component. |
| Fullscreen/maximize restore geometry and operation ordering | Actual `Window`, including when two component hosts both call it logical zero. Serializing one window must not block an unrelated window. | `WindowManager` accepts an actual `Window` in operation options and stores queues/snapshots by that object. |
| File dialog parent | `parentWindowId = 0` resolves through the requesting component. A positive ID resolves through the window registry. An Ability-only caller without a component must omit the parent or supply an available registered window. | `FilesPlugin` uses the parent's UIContext/AbilityContext when constructing `DocumentViewPicker`. |
| Keyboard delivery configuration while rendering | Current framework lifecycle guard. The option lives in `OpenHarmonyAppInner` and must be set before active render surfaces. This protects the installed delivery path; it is not a HarmonyOS ban on changing window input behavior. | `OpenHarmonyApp.set_keyboard_input_delivery`. |
| One active bridge host/root per native module | Current ABI/runtime constraint, retained. A module exports a single app instance and bridge/root ownership. Different modules may have independent hosts; an app can also render multiple child windows through `renderWindow`. This must not be described as one UIAbility/window per process. Removing the guard requires a session-aware app/root ABI. | `BridgeHostRegistry.moduleOwners`, `BridgeHost.attachComponent`, `crates/derive` app singleton and render ownership. |
| ArkWeb engine and custom-scheme declarations | Shared engine initialization with coordinated scheme declarations is justified. Scheme registration must finish before engine startup. WebView request handlers remain scoped by web tag, and controller callbacks remain window-owned. | [Custom scheme registration and per-WebView handlers](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkweb/capi-arkweb-scheme-handler-h.md#oh_arkweb_registercustomschemes). |
| Clipboard | Native `OH_Pasteboard` is the only data path. Native owners are operation-scoped; no listener, permission prompt, bridge data transport or shared cache exists. The caller owns scheduling/authorization. | The HAR preserves registration identity only. Rust `revision()` pulls the API-18 counter; zero is unknown and service restart can reset it. |
| Pointer visibility | The existing native API accepts no target window, while the public documentation describes the current window. Upstream drawing state includes per-PID visibility records. Keeping this request without a window ID reflects that native interface; this does not prove that all windows must share application-level cursor policy. | [Pointer API](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-input-kit/js-apis-pointer.md#pointersetpointervisible), [pointer drawing state](https://github.com/openharmony/multimodalinput_input/blob/master/service/window_manager/src/pointer_drawing_manager.cpp). |
| Hidden independent UIAbility windows | Deferring platform launch is a framework workaround to avoid foreground activation, not a process-wide window constraint. Size, position and background color can be configured on the pending logical window. Operations needing a native window fail as not ready until explicit show/focus/restore. | `WindowManager.createAbilityWindow` / `configureDeferredWindow` / `waitForWindowCreation`. |

## Menu lifecycle

Core pages look up the builder and key-event port using their actual window. Plugin bindings use a native-window key, while bridge events retain the existing logical `main`/numeric window IDs. Child windows bind on their first menu request, inherit the requesting plugin's options, and wait for the real ArkUI mount callback. Call cancellation or host disappearance releases that wait; no timer guesses page readiness.

A window has one active registration for the standard menu slot. An explicit registration replaces the prior owner for that window only. Release functions check registration identity, so an older owner's teardown cannot remove its replacement. A request awaiting attachment rejects if ownership changed before it resumed. This is ownership of the framework's menu slot, not a platform rule limiting how many menu components an application may render.

The public unscoped `setMenuBarSlotBuilder`, `setMenuBarPort` and `setPredefinedActionExecutor` functions remain available for existing consumers that explicitly configure a shared fallback. Built-in menu plugins do not use these fallbacks to install instance configuration. A process-wide `configureMenuPresentation` restriction is intentionally absent.

Existing `getMenuBarPort()` callers keep routing by the logical ID passed to the port method. Ambiguous zero retains the first registered root; integrations that distinguish component-local zero aliases must pass their actual window to `getMenuBarPort(win)`. Direct `MenuBarComponent` embeddings and legacy builders derive the native menu key from their UIContext when no explicit `menuKey` is supplied. Custom registries may still supply an explicit key.

API 12–19 menu dismissal uses the existing `aboutToDisappear`/`onDisappear` callbacks. `ModalMode` and anchor positioning are accessed only on API 20 or newer. A missing operation target is handled explicitly; null-to-undefined conversion must not silently select the primary window.

## Remaining architectural boundaries

Native input and Web engine capabilities are selected through
[Cargo features](native-capabilities.md). Older deployments must leave newer
API features disabled; there is no runtime symbol probe or missing-symbol fallback.

This change does not make all older window registries session-aware. Positive logical window IDs in `WindowManager`, legacy primary-module notification paths, and primary-Ability startup/restore bookkeeping still follow the existing shared-runtime contract. Treat these as framework boundaries when introducing multiple independent runtimes; they are not evidence of platform-wide limitations.

The pre-existing WebView `NewWindowDialog` helper also stores one active popup globally. Opening another popup closes the prior one, including across hosts. This is an implementation limitation, not an ArkUI restriction or a requirement of browser popup behavior; it needs a separate dialog-ownership change.

The hidden-window creation promise continues to represent native readiness. The caller already owns its logical ID and can configure pending attributes without awaiting native readiness. Explicit show/focus/restore starts the native creation and completes that promise. Other native operations now reject promptly instead of waiting for a show request that the caller cannot reach.

## Validation

SDK-backed runtime tests cover two hosts both using logical zero, distinct menu policies and event routes, stale-owner disposal, mount cancellation, window-owned controller callbacks, fullscreen geometry/ordering, file-dialog parenting, and hidden-window configuration before launch. The demo HAP is also compiled against the installed SDK. These checks substitute native effects in host tests; they do not establish emulator or device acceptance.

## Native prompt appearance

`show-prompt` accepts an optional named `PromptAppearance` with seven ARGB semantic colors. Omitted colors use the target window's system theme; supplied colors are snapshotted when the dialog opens. Theme selection belongs to the application, not the window plugin. Translucent surfaces and controls are composited to opaque colors, and unreadable text/focus colors are replaced with a contrasting neutral. Message, action indices, cancellation and default focus retain the caller's semantics.
