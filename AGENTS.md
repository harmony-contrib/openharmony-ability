# AGENTS.md

## Project Overview

`openharmony-ability` is a Rust + ArkTS framework for OpenHarmony (HarmonyOS) applications. Rust provides lifecycle management and typed, worker-safe plugin facades; the ArkTS `NativeAbility` package (`@ohos-rs/ability`) owns all platform objects and drives the real platform calls. The two sides communicate over an N-API bridge (`napi-ohos`) using stable named N-API types — **never JSON**. Native modules are built for `*-unknown-linux-ohos` targets; the host (macOS) can only run Rust unit tests, not the app. Licensed under MIT.

## Build Commands

```bash
# Check the whole workspace
cargo check --workspace

# Host unit tests for a plugin crate (typeName / validation / mode+context assertions)
cargo test -p openharmony-ability-plugin-<name> --lib

# Lint: oxk lint for ArkTS/TS + clippy per OHOS arch with -D warnings
# (clippy excludes webview_example and xcomponent_example)
pnpm run lint

# Format: cargo fmt + oxk format for **/*.{ets,js,ts,json5}
pnpm run format
pnpm run format:check   # CI check-only form

# Pre-commit hooks (rustfmt, oxk format, oxk lint)
pnpm run prek

# Build the native demo cdylib for a device
cd rust_example/demo_native && ohrs build --arch arm64

# Forbidden JSON-bridge scan — must stay empty
rg -n "BridgeJson|call_json|bridgeJson|requireBridgeJson|JSON\.stringify|JSON\.parse" \
  crates/plugin-* plugins/*/src native_ability
```

## Architecture

```
ArkTS UI (UIAbility / DefaultXComponent)
   │  owns platform objects: UIAbilityContext, WindowStage, UIContext,
   │  WebviewController, FrameNodes, lifecycle listeners
   ▼
NativeAbility (BridgeHost, per-module component root, BridgePluginFactory registry)
   │  async via TSFN (Promise→future); worker→main sync via TSFN; events inside active napi_env
   │  transport: named N-API values only (typeName-validated at the boundary)
   ▼
crates/ability bridge (BridgeRuntime / BridgeMainThread / PluginLifecycleEvent)
   │
   ▼
Rust plugin facades (BridgePlugin) + application business code (run_loop)
```

### Workspace Crates

| Crate | Purpose |
|-------|---------|
| `crates/ability` | Core: lifecycle/`run_loop`, bridge transport (`impl_bridge_napi_type!`, `BridgeNapiType`, `BridgePlugin`, `BridgeRuntime`, `BridgeHost`), ArkUI/xcomponent/ime binding re-exports |
| `crates/derive` | `#[ability]` entry macro |
| `crates/plugin-permission` | `ohos.permission` — async permission request |
| `crates/plugin-app-control` | `ohos.app-control` — sync main-thread terminate |
| `crates/plugin-window` | `ohos.window` — async avoid-area and multi-window operations |
| `crates/plugin-webview` | `ohos.webview` — WebView create, controller, custom protocol, JS proxy, callbacks |
| `crates/plugin-files` | `ohos.files` — file dialogs (open/save/folder) |
| `crates/plugin-url` | `ohos.url` — `context.openLink` |
| `crates/plugin-resource` | `ohos.resource` — inbound-only: ArkTS pushes `resourceManager` from Ability-scoped `onInstall`; no outbound actions |

Every `crates/plugin-<name>` is paired with an ArkTS HAR in `plugins/<name>` that exports the matching `BridgePluginFactory`; core (`crates/ability`) never imports any `plugin-*` crate.

### Startup Flow

1. `NativeAbility.onCreate` opens each module/session `BridgeHost`, injects that module's bridge transport independently from rendering, then uses the Rust registry's `{ id, execution, requires }` declarations to select matching ArkTS factories before emitting `ability-create`. Plugins and application registration never select by module.
2. `NativeAbility.onWindowStageCreate` provides the `WindowStage`, emits `window-stage-create`.
3. Each `DefaultXComponent.aboutToAppear` binds one distinct native module, resolves and observes that component's actual `Window`, injects that module's root `FrameNode`, then emits its `ui-context-ready`. One Ability may host multiple components/modules, including across windows; the same module cannot back two components concurrently.
4. Rust entry: `#[ability] fn init(app: OpenHarmonyApp)` → `app.register_plugin(P)…` then `app.run_loop(|event| …)`.
5. Per-module teardown order: `ui-context-destroy` → component detach → `window-stage-destroy` → `ability-destroy` → dispose host/session.

### Key Patterns

- **`BridgePlugin` trait** (`crates/ability/src/bridge/mod.rs`) — the stable Rust contract: `type Mode = AsyncBridge | MainThreadSyncBridge`, `const ID`, `REQUIRED_CONTEXTS` (`ability` | `window-stage` | `ui-context`). `Mode` is a closed trait, not a runtime flag. There is no numeric plugin version; incompatible ABI changes use a new action/typeName.
- **`impl_bridge_napi_type!(T, "ohos.<plugin>.<TypeName>")`** — pins a stable ABI typeName for `#[napi(object)]` structs; ArkTS validates the same string at parse and backfills it on response.
- **Async mode** — Rust worker calls `BridgeRuntime::call_async::<P, Req, Resp>("action", req, options)`; data must be `Send + 'static`; the TSFN turns the ArkTS Promise into a future.
- **Sync mode** — main thread: inside an active N-API callback, `app.with_main_thread_bridge(env, |b| b.call_sync::<P, Req, Resp>(…))`; workers: `BridgeRuntime::call_sync_from_worker` (TSFN, execution still on the main thread, must not be called from the N-API main thread). `BridgeMainThread` is `!Send + !Sync`, never cached.
- **Platform callbacks** — ArkTS normally calls instance-scoped `context.invokeNativeSync(event, reqTypeName, respTypeName, value)`; Rust answers in `BridgePlugin::on_main_thread_event` within the same callback. Only genuinely process-global transitions (ArkWeb engine initialization) use `invokeNativeSyncProcessWide`. Fail-open (navigation) vs fail-closed (download) per event.
- **One component tree per native module** — each `DefaultXComponent` owns the single root `FrameNode` for its module, injected before that host's `ui-context-ready`; plugins mount via `context.appendChild(key, node, cleanup)` / `removeChild(key)`. Multiple components/windows use multiple modules, while multiple WebViews in one component use distinct IDs. Built-in `ohos.node` gives Rust opaque u32 handles; `FrameNode` values never cross N-API.
- **Component-window routing** — `windowStageEvent` remains Ability-scoped, but size/rect/avoid-area/keyboard listeners are attached to the actual `Window` resolved from each component's `UIContext`; those events are never broadcast from the main window to sub-window modules.

## Plugin Contract Rules

Read `docs/plugin-development-standard.md` (the single authoritative spec, Chinese) and invoke the bundled `named-napi-contracts` skill before adding or modifying any plugin. Non-negotiable rules:

- Paired packages only: `crates/plugin-<name>` + `plugins/<name>`. ID, Mode, and requires must be **identical on both sides** (`BridgeHost.configurePlugins` hard-validates). `LazyPlugin` has no module filter; each Rust registry selects its own matching factory.
- **No JSON across the bridge, ever.** All requests/responses/platform callbacks are named N-API values. `BridgeJson`, `call_json`, `bridgeJson`, `requireBridgeJson`, `JSON.stringify/parse` are banned. Built-in scalars: `std.string`, `std.bytes`, `std.bool`, `std.i32`, `std.f64`.
- Actions are kebab-case verb phrases (`create`, `get-avoid-area`, `evaluate-script`); IDs/actions/typeNames match `^[A-Za-z0-9._-]+$`. Rust fields snake_case, ArkTS camelCase.
- Never store `Env`, `napi_value`, `napi_ref`, ArkTS objects/functions in workers, statics, or long-lived caches. Sync paths never `await`; async paths never hold `Env`.
- Platform objects live in ArkTS only. Plugins subscribe to the lifecycle chain — never replace `NativeAbility` lifecycle callbacks. `onDispose` must be idempotent and must not block other plugins' dispose.
- WebView specifics: schemes must be registered via `WebviewProtocol::register` **before** `WebviewController.initializeWebEngine()`; custom protocol (URL requests) and JS proxy (`window.<obj>.<method>()`) are distinct bridges; `transparent` is expressed at `create` time.

## Adding a New Plugin

Follow the local spec `docs/plugin-development-standard.md` (§1 creation order, §3 named N-API contracts, §8 registration/assembly, §9 acceptance checklist) plus the full implementation checklist in the bundled `.agents/skills/named-napi-contracts/` skill.

## Key Dependencies

- **N-API bridge**: `napi-ohos`, `napi-derive-ohos`, `napi-build-ohos`, `napi-sys-ohos` (1.2, napi8)
- **OHOS bindings**: `ohos-arkui-binding`, `ohos-xcomponent-binding`, `ohos-web-binding`, `ohos-ime-binding`, `ohos-display-binding`, `ohos-hilog-binding`, `ohos-resource-manager-binding`
- **Tooling**: pnpm@10.22.0; `@ohos-rs/oxk` (oxk format/lint for ets/js/ts/json5); `@j178/prek` hooks; `ohrs` for native module builds
