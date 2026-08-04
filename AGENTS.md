# AGENTS.md

## Project Overview

`openharmony-ability` is a Rust + ArkTS framework for OpenHarmony (HarmonyOS) applications. Rust provides lifecycle management and typed, worker-safe plugin facades; the ArkTS `NativeAbility` package (`@ohos-rs/ability`) owns all platform objects and drives the real platform calls. The two sides communicate over an N-API bridge (`napi-ohos`) using named, versioned N-API types — **never JSON**. Native modules are built for `*-unknown-linux-ohos` targets; the host (macOS) can only run Rust unit tests, not the app. Licensed under MIT.

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
ArkTS UI (UIAbility / DefaultXComponent / BridgeNodeHost)
   │  owns platform objects: UIAbilityContext, WindowStage, UIContext,
   │  WebviewController, FrameNodes, lifecycle listeners
   ▼
NativeAbility (BridgeHost, BridgeNodeSlot, BridgePluginFactory registry)
   │  async via TSFN (Promise→future), sync/events inside active napi_env
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
| `crates/plugin-window` | `ohos.window` — sync avoid-area query |
| `crates/plugin-webview` | `ohos.webview` — WebView create, controller, custom protocol, JS proxy, callbacks |
| `crates/plugin-files` | `ohos.files` — file dialogs (open/save/folder) |
| `crates/plugin-url` | `ohos.url` — `context.openLink` |
| `crates/plugin-resource` | `ohos.resource` — inbound-only: ArkTS pushes `resourceManager` at ability-create; no outbound actions |

Every `crates/plugin-<name>` is paired with an ArkTS HAR in `plugins/<name>` that exports the matching `BridgePluginFactory`; core (`crates/ability`) never imports any `plugin-*` crate.

### Startup Flow

1. `NativeAbility.onCreate` opens the module/session `BridgeHost`, creates factories, emits `ability-create`.
2. `NativeAbility.onWindowStageCreate` provides the `WindowStage`, emits `window-stage-create`.
3. `DefaultXComponent.aboutToAppear` attaches the native event sink and default node slot `xcomponent-overlay`, emits `ui-context-ready` (plugins install here and may immediately use scoped callbacks or mount nodes).
4. Rust entry: `#[ability] fn init(app: OpenHarmonyApp)` → `app.register_plugin(P)…` then `app.run_loop(|event| …)`.
5. Teardown order: `ui-context-destroy` → detach slots/sink → `window-stage-destroy` → `ability-destroy` → dispose session.

### Key Patterns

- **`BridgePlugin` trait** (`crates/ability/src/bridge/mod.rs`) — the stable Rust contract: `type Mode = AsyncBridge | MainThreadSyncBridge`, `const ID`, `const VERSION`, `REQUIRED_CONTEXTS` (`ability` | `window-stage` | `ui-context`). `Mode` is a closed trait, not a runtime flag.
- **`impl_bridge_napi_type!(T, "ohos.<plugin>.<TypeName>")`** — pins a stable ABI typeName for `#[napi(object)]` structs; ArkTS validates the same string at parse and backfills it on response.
- **Async mode** — Rust worker calls `BridgeRuntime::call_async::<P, Req, Resp>("action", req, options)`; data must be `Send + 'static`; the TSFN turns the ArkTS Promise into a future.
- **Sync mode** — only inside an active N-API callback: `app.with_main_thread_bridge(env, |b| b.call_sync::<P, Req, Resp>(…))`. `BridgeMainThread` is `!Send + !Sync`, never cached.
- **Platform callbacks** — ArkTS calls `context.invokeNativeSync(event, reqTypeName, respTypeName, value)`; Rust answers in `BridgePlugin::on_main_thread_event` within the same callback. Fail-open (navigation) vs fail-closed (download) per event.
- **`BridgeNodeSlot`** — node mounting keyed `(sessionId, moduleName, slotId)`; default slot `xcomponent-overlay`, business named slots via `BridgeNodeHost`. Waiters honor `context.onCancel`; no timers/polling for readiness.

## Plugin Contract Rules

Read `docs/plugin-development-standard.md` (the single authoritative spec, Chinese) and invoke the bundled `named-napi-contracts` skill before adding or modifying any plugin. Non-negotiable rules:

- Paired packages only: `crates/plugin-<name>` + `plugins/<name>`. ID, VERSION, Mode, and requires must be **identical on both sides** (BridgeHost.lookup hard-validates).
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
