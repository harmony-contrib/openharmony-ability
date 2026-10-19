> [!IMPORTANT]
> Remove this line to confirm you've reviewed this PR before submitting.

# OpenHarmony Ability

English | [简体中文](README.zh-CN.md)

> This project is in progress, and the API is not stable.

`openharmony-ability` provides native integration helpers for OpenHarmony applications: Rust-side lifecycle management plus ArkTS-side entry helpers that can be shared by Rust and C/SDL native modules.

See the [changelog](CHANGELOG.md) for release notes and per-package changes.

## Architecture

OpenHarmony applications are driven by callbacks, so there are two important constraints:

1. Do not block the main thread.
2. `run_loop` does not retain user resources for you, so resources that must outlive setup need stable ownership.

![Architecture](/fixtures/openharmony-ability.png)

## Repository Layout

- `crates/ability` — Rust lifecycle/runtime support
- `crates/derive` — `#[ability]` macro
- `native_ability` — ArkTS package source shared by Rust and C/SDL native modules
- `plugins/*` — standalone ArkTS capability packages
- `demo` — unified Harmony demo project
- `rust_example/demo_native` — unified native demo implementation

## Development setup

```bash
pnpm install
```

This installs the `ohpm-rs` CLI from `ohpm-cli` 0.3.0 and installs ArkTS dependencies
for the workspace packages and demo. Internal ArkTS dependencies use `workspace:*`
and resolve to the source packages listed in `ohpm-workspace.yaml`.
Run `pnpm run install:ohpm` to reinstall ArkTS dependencies after changing a manifest.

The repository commands use Node and Rust tools on Linux and macOS. Native Windows
is currently blocked by `ohpm-cli` 0.3.0's Unix-only dependency-link implementation;
use WSL with Linux tools and SDK until the CLI supports Windows.

Run `npm run pack` to create one HAR per workspace package in `dist/`.

Run `npm run format` to format Rust and ArkTS sources. Git hooks run formatting and
lint checks through prek; CI runs prek for all files and Rust clippy for each
supported OpenHarmony target.

## Usage

1. Add Rust dependencies:

```bash
cargo add openharmony-ability
cargo add openharmony-ability-derive
cargo add napi-ohos
cargo add napi-derive-ohos
cargo add napi-build-ohos
```

2. Implement your native entry (Rust example):

```rust
use ohos_hilog_binding::hilog_info;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;

#[ability]
fn openharmony_app(app: OpenHarmonyApp) {
    app.run_loop(|event| {
        hilog_info!(format!("event: {:?}", event.as_str()).as_str());
    });
}
```

3. Use `NativeAbility` in ArkTS:

```ts
import { NativeAbility } from "@ohos-rs/ability";
import Want from "@ohos.app.ability.Want";
import { AbilityConstant } from "@kit.AbilityKit";

export default class EntryAbility extends NativeAbility {
  public moduleName: string = "demo_native";

  onCreate(
    want: Want,
    launchParam: AbilityConstant.LaunchParam
  ): void {
    super.onCreate(want, launchParam);
  }
}
```

4. Build the native module:

```bash
cd rust_example/demo_native
ohrs build --arch arm64
```

## Demo

- Harmony demo project: `demo`
- Native demo module (Rust example): `rust_example/demo_native/src/lib.rs`
- ArkTS package source: `native_ability`

## Plugin configuration

Plugin factories require business-owned protocol configuration:

```ts
new LazyPlugin(() => new ClipboardPlugin({ metadataMimeType: "application/x-my-app-metadata-v1" }));
new LazyPlugin(() => new NotificationPlugin({ scheme: "my-app-notification" }));
```

Register the standalone plugin factories in the Ability's `bridgePlugins` array.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).


## Desktop runtime adaptation

The runtime supports independently managed window Abilities, window-owned
native menus and prompts, per-window IME ownership, synchronous content focus,
and cancellation when windows or bridge sessions are destroyed. Keyboard input
readiness is independent of rendering Surface creation. Applications opting into
these paths must update their native render exports and ArkTS runtime together.

Independent window recovery delegates to `NativeWindowAbility.restoreApplication(want)`;
hosts may override it to restore their own document or workspace. The default
forwards the launch Want to the application's entry Ability. Window teardown
notifies its creating native module, and close interceptors have independent
registrations even when modules share an Ability session.

Fullscreen and maximized Ability windows retain system-managed geometry.
`focusOnShow` is only guaranteed for child windows by the SDK; it cannot promise
non-activating launches of independent UIAbility main windows. These capabilities
must be verified separately from successful creation or parameter delivery.

`MenuPlugin({ showMenuBar: false, handleKeyboardShortcuts: false })` retains native
popups while leaving menu placement and contextual accelerators to the application.
Interactive prompts and permission requests use `BridgeCallOptions::for_user_interaction()`;
session teardown still cancels them. The files plugin supports `open-mixed` and an
optional `parentWindowId`. Explicit clipboard reads can request permission after a
denied read; background refreshes never open permission UI.

Run SDK-backed runtime checks with Node 22+:

```sh
OHOS_SDK_HOME=/path/to/openharmony node --test scripts/runtime-regressions.cjs
python3 scripts/keyboard-focus-regressions.py
```

These host checks substitute native APIs and do not establish device timing.
Task-center close/restore and input typed during creation of another window still
require further work; this adaptation does not claim complete desktop parity.
