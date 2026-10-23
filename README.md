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

## Native window input

Ability owns one asynchronous input FIFO per native module. Native callbacks copy owned input into it;
the lifecycle waker drains input and `Event::UserEvent` on the same N-API/UI-thread turn.
IME callbacks never invoke application code or wait for a foreground task. Each editor
lifetime has an `Arc` owner token: retirement drops queued edits and rejects callbacks
already running for the old editor, including when an owner name is reused.

With `keyboard` and `KeyboardInputDelivery::ArkUi`, `ArkUiInputEvent::Key` reports each
physical down/up transition once. `KeyboardEventData::ime_consumed` is true when an
owner's IME edit resolves that dispatch, or no post-IME callback reaches the component
before its queued delivery. Pre/post callbacks resolve the current dispatch, never
deduplicate timestamps. This is an Ability correlation contract, not a native
consumed-result API; hardware IME callback ordering must be verified on supported
devices. Long-press/click semantic callbacks are not additional transitions.

Consumers update modifier/held-key state for every transition, but must not execute
shortcuts or insert hardware text for consumed keys. Unconsumed post-IME keys can call
`key_event.response.consume()` synchronously in the input handler to mark the native
key consumed. Remove timestamp deduplication and the former `KeyPreIme` duplicate stream.
Baseline `RawXComponent` remains a legacy post-IME-only stream; it cannot observe keys
the IME does not forward.

Use `try_attach_ime_for(window_id)` to attach without opening the keyboard and
`try_show_keyboard_for(window_id)` to attach/show explicitly. Ability detaches the
previous editor before switching windows; an error prevents ownership transfer.
`try_detach_ime_for` releases editor focus, while `hide_keyboard_for` only hides the
keyboard. Configure API-26 native key consumption explicitly through `with_ime_for`
with the `api-26` feature before attachment; it is not consumer policy
enabled by default. Native operations are UI-thread-only and never use attachment
workers or a process-wide binding session registry.

Native drag acceptance remains a callback-scoped synchronous reply: delaying it would
return the default rejection to the platform. This narrow path never drains user wakes
or foreground tasks and does not create another keyboard/IME channel.

`Event::TextInputReadyChanged { window_id, ready }` is independent of EGL surface
creation. Query `is_text_input_ready_for`; invalidate cached attachments on every
readiness event. `reset_ime_for` retires an editor before recreating it; reapply its
configuration/text snapshot afterwards. `set_text_input_active_for` controls the
XComponent keyboard-demand flag independently of soft-keyboard visibility.

ArkTS render exports accept optional `platformWindowId`. Missing/zero selects the
platform main window. The component's real Window ID is separate from framework
routing IDs; failure to look up the main window logs and uses zero, while subwindow
assembly must resolve a real positive platform ID instead of silently targeting main.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
