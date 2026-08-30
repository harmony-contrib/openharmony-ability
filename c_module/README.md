# c_module — Pure C access to the ArkTS bridge

This directory adds a **pure C** path to the `@ohos-rs/ability` ArkTS host, mirroring how the
[richerfu/SDL](https://github.com/richerfu/SDL) OHOS backend integrates: business code written in
C99 implements the same eight-function native module contract (`init` / `disposeBridge` /
`render` / `disposeRender` / `disposeAllRenders` / `onBackPressIntercept` /
`onBridgeSyncEvent` / `onBridgeLifecycle`) and drives the existing ArkTS plugins through the
typed N-API bridge — no Rust, no C++ ABI and no JSON transport.

```
c_module/
├── ability/                  # Pure C framework library (static `oh_ability`)
│   ├── include/
│   │   ├── oh_ability.h      # Public C API (SDL-style entry model)
│   │   └── oh_ability_events.h
│   └── src/                  # module/lifecycle/bridge/registry/xcomponent/ime/node/...
├── example/demo_native/      # Pure C demo native module (libdemo_native.so)
    ├── src/
    │   ├── main.c            # NAPI entry + application callbacks + plugin assembly
    │   ├── exports.c         # export table (demo.* exports + plugin exports)
    │   ├── bridge_demos.c    # shared helpers (deferred/object plumbing, back-press)
    │   └── plugins/          # one directory per plugin (Rust crates/plugin-* layout)
    │       ├── permission/   # ohos.permission
    │       ├── files/        # ohos.files
    │       ├── url/          # ohos.url
    │       ├── resource/     # ohos.resource (inbound plugin)
    │       ├── webview/      # ohos.webview (inbound plugin + scheme + JS proxy)
    │       ├── window/       # ohos.window (reserved)
    │       └── app-control/  # ohos.app-control (reserved)
│   └── types/libdemo_native/ # Index.d.ts aligned with the Rust demo's export surface
└── example/sdl_demo_native/  # SDL3 validation module (libsdl_demo_native.so)
```

## What the framework provides

- **Module contract** — `OHAbility_RegisterModule(env, exports)` exports the eight functions the
  ArkTS host expects. `init(bindings, bridgeOwner, context?)` owns the Ability bridge session and
  returns `ApplicationLifecycle`; `render(slot, renderOwner)` independently owns one component
  tree, with stale-owner-safe teardown on both sides.
- **SDL-style application model** — `OHAbility_StartApp()` with
  `AppInit` / `AppIterate` / `AppEvent` / `AppQuit` callbacks. The application thread starts
  automatically when the first XComponent surface is created.
- **Bridge calls** —
  - `OHAbility_CallAsync` / `OHAbility_CallAsyncPromise` (any thread; request builders and
    response handlers run on the ArkTS main thread),
  - `OHAbility_CallSync` (main-thread N-API callbacks only),
  - `OHAbility_CallSyncFromWorker` (worker blocks; execution on the main thread).
- **C plugins** — `OHAbility_RegisterPlugin(id, plugin, userdata)` declares the same closed
  execution mode and required contexts as ArkTS, receives named N-API main-thread events
  (`context.invokeNativeSync(...)`), and activates only after its contexts are ready. There is no
  numeric plugin version and no module filter.
- **Built-in `ohos.node` surface plugin** — `OHAbility_NodeCreateContainer` /
  `OHAbility_NodeAppendChild` / `OHAbility_NodeMountIntoRoot` / `OHAbility_NodeDispose` compose
  this module's component tree through opaque handles. The plugin
  is installed automatically by the ArkTS BridgeHost; the C side is outbound-only (Rust
  `NodeExt` / `NodeSurface` parity), and acknowledgement rejection surfaces as an error.
- **Event surface** — lifecycle, window stage, configuration, memory, surface, raw touch,
  key/mouse/hover, ArkUI axis, tap/pan/swipe gestures, frame callbacks, IME, keyboard height and
  avoid areas; delivered as a tagged union (`oh_ability_events.h`). Raw touch versus semantic
  gesture delivery is selected with `OHAbility_SetTouchInputDelivery` before render.
- **Platform access** — init context (`basePath` / `prefPath` / `preferredLocales` /
  `moduleName`), native `resourceManager`, `OHNativeWindow`, frame-rate ranges, back-press
  interception, saved-state slot, IME show/hide, `OHAbility_Wake`.
- **Snapshot accessors (Rust `OpenHarmonyApp` parity)** — `OHAbility_GetConfiguration`,
  `OHAbility_GetContentRect`, `OHAbility_GetWindowRect`, `OHAbility_GetAvoidArea(type)`,
  `OHAbility_GetScale` (display density), kept in sync with the latest platform callbacks.

## Threading rules (the framework enforces these)

- N-API values never cross threads and never live in long-lived storage: `ValueBuilder` and
  `ValueResponder` callbacks always run on the ArkTS main thread with a live `napi_env`.
- `OHAbility_CallSync` is rejected outside the main-thread N-API environment;
  `OHAbility_CallSyncFromWorker` is rejected on the main thread (deadlock guard).
- Event strings are owned by the framework for the duration of `AppEvent` only.

## Plugin switches (compile-time macros)

Every plugin (and the two platform capabilities) is gated by a macro, mirroring cargo features
/ SDL subsystems. All default to ON; disabled plugins keep their export names as explicit-error
stubs so the demo Index page still imports cleanly, and their platform libraries are not linked.

| Macro | Scope | Effect when OFF |
| --- | --- | --- |
| `OH_ABILITY_PLUGIN_NODE` | framework | built-in `ohos.node` facade not compiled (`OHAbility_Node*` undeclared); composed webview stub |
| `OH_ABILITY_PLUGIN_PERMISSION` | demo | `demoRequestPermissionFromMainThread` stub |
| `OH_ABILITY_PLUGIN_FILES` | demo | `demoFileDialogOpen`/`Save` stubs |
| `OH_ABILITY_PLUGIN_URL` | demo | `demoOpenUrl` stub |
| `OH_ABILITY_PLUGIN_RESOURCE` | demo | `ohos.resource` inbound plugin not registered; resource exports stub |
| `OH_ABILITY_PLUGIN_WEBVIEW` | demo | webview plugin/demos stub; `libohweb` not linked |
| `OH_ABILITY_PLUGIN_WINDOW` | demo | reserved (no demo surface yet) |
| `OH_ABILITY_PLUGIN_APP_CONTROL` | demo | reserved (no demo surface yet) |
| `OH_ABILITY_ENABLE_IME` | framework | IME support not compiled; `libohinputmethod` not linked |
| `OH_ABILITY_ENABLE_DISPLAY` | framework | display accessor is not declared; `libnative_display_manager` not linked |

```bash
# Build with plugins disabled
cmake -S c_module -B c_module/build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<SDK>/native/build/cmake/ohos.toolchain.cmake \
  -DOHOS_ARCH=arm64-v8a \
  -DOH_ABILITY_PLUGIN_WEBVIEW=OFF -DOH_ABILITY_PLUGIN_RESOURCE=OFF
```

## Building

```bash
# Build for a device ABI (defaults to arm64-v8a)
scripts/build-c-demo.sh

# Build and install into the demo app (replaces the Rust-built libdemo_native.so)
scripts/build-c-demo.sh --install

# Other ABIs / clean
scripts/build-c-demo.sh --arch=x86_64 --clean

# Build the SDL3 adapter/demo from /Volumes/PSSD/sdl/SDL
scripts/build-sdl-demo.sh

# Build and copy libsdl_demo_native.so into the demo HAP's native libs
scripts/build-sdl-demo.sh --install
```

The script resolves the OHOS SDK from `$OHOS_SDK` or the newest DevEco Studio installation and
uses the SDK-bundled cmake/ninja when present. The demo app is untouched unless `--install` is
passed; `libdemo_native.so` is git-ignored (`*.so`), so the C module can be swapped in and out
of the demo without affecting the repository.

## Demo

`c_module/example/demo_native` is the pure C counterpart of `rust_example/demo_native`: it reuses
the `demo_native` module name and the exact export surface of the Rust demo
(`types/libdemo_native/Index.d.ts`), so the demo app's Index page runs unchanged against a pure C
backend. Every `demo*` export is a thin wrapper over the bridge:

| Demo | Bridge path |
| --- | --- |
| `demoPluginString` / `demoPluginBytes` / `demoPluginProfile` | `demo.raw` echo / reverse-bytes / bump-profile |
| `demoPluginLogin` | `demo.login` authorize → publish chain |
| `demoPluginSyncContext` / `demoPluginSyncFromWorker` | `demo.main-thread` inspect (sync / worker-sync) |
| `demoRequestPermissionFromMainThread` | `ohos.permission` request |
| `demoOpenUrl` | `ohos.url` open-url |
| `demoFileDialogOpen` / `demoFileDialogSave` | `ohos.files` file-dialog |
| `createDemoWebview` / composed / bottom | `ohos.webview` create (+ `ohos.node` for composed) |
| `setBackgroundColor` / `setVisible` / `evaluateDemoWebviewScript` | `ohos.webview` controller actions |
| `demoResourceManagerReady` / `demoResourceRawDirCount` | native `resourceManager` (rawfile) |
| `toggleBackPressIntercept` | framework back-press interceptor |

The module registers matching declarations for every plugin it calls. `ohos.resource` answers the
ArkTS-pushed `resource-manager-ready` event, while `ohos.webview` answers `seal-engine-schemes`,
`before-engine-init`, `engine-initialized`, `controller-attached`/`removed`,
`navigation-request`, `download-start`, `download-end`, and `title-change`. Engine-global events
use the Ability requirement; controller events require the module's UI context.

WebView parity with the Rust demo:

- The custom `demoweb` scheme is registered at module import time (before the WebView engine
  initializes) and served natively on the ArkWeb IO thread (`ArkWeb_SchemeHandler` +
  `ArkWeb_ResourceHandler`, responding with the same page as the Rust demo's index.html).
- The `window.test` JavaScript proxy is registered on `controller-attached` through
  `OH_NativeArkWeb_RegisterJavaScriptProxy`, before the initial load.
- The demo page (`demoweb://index`) mirrors the Rust page, including the `test test !` proxy
  button; `evaluateDemoWebviewScript` returns the same `document.title`.

The application thread runs the SDL-style callbacks and logs events; state saving uses the
framework's saved-state slot.

### SDL3 integration demo

The checkout selected by `OH_ABILITY_SDL_SOURCE_DIR` (the build script defaults to
`/Volumes/PSSD/sdl/SDL`) owns the integration template at
`examples/ohos/oh_ability`. This repository keeps only the validation demo. SDL no longer has a
standalone N-API/XComponent owner: `oh_ability` owns the current eight-export contract and the
single XComponent, while the SDL-side adapter binds `OHAbility_GetNativeWindow()` and forwards
lifecycle, resize, content-rect, avoid-area, keyboard-height, touch, mouse, wheel, hardware-key
and IME events.

The SDL-side template also migrates the previous ArkTS helpers to the mainline named plugin
contracts (`ohos.permission`, `ohos.files`, `ohos.url`, `ohos.resource`,
`ohos.app-control`). Request and response values are named N-API objects; no JSON bridge or
compatibility entry remains.

`c_module/example/sdl_demo_native` uses SDL3's renderer to draw an animated surface and live input
counters. The Demo app exposes it as the separate `sdl_demo_native` module on the **SDL3** tab, so
it also validates the mainline rule that each `DefaultXComponent` has a distinct native module.

## Verification

```bash
scripts/build-c-demo.sh            # builds libdemo_native.so
scripts/build-c-demo.sh --install  # installs it into demo/entry/libs/arm64-v8a/
scripts/build-sdl-demo.sh          # builds libsdl_demo_native.so against SDL3
scripts/build-sdl-demo.sh --install
```

Then build the demo app (DevEco Studio or `hvigorw assembleHap`) and run it on a device:
lifecycle logs (`ohAbility` / `ohosCDemo` HiLog tags), the XComponent surface, and every demo
button should behave like the Rust demo. Switch back by rebuilding the Rust module
(`cd rust_example/demo_native && ohrs build --arch arm64`) and copying its `dist/arm64-v8a/
libdemo_native.so` into `demo/entry/libs/arm64-v8a/`.
