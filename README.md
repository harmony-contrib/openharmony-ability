# OpenHarmony Ability

> This project is in progress, and the API is not stable.

`openharmony-ability` provides native integration helpers for OpenHarmony applications: Rust-side lifecycle management plus ArkTS-side entry helpers that can be shared by Rust and C/SDL native modules.

## Architecture

OpenHarmony applications are driven by callbacks, so there are two important constraints:

1. Do not block the main thread.
2. `run_loop` does not retain user resources for you, so resources that must outlive setup need stable ownership.

![Architecture](/fixtures/openharmony-ability.png)

## Repository Layout

- `crates/ability` — Rust lifecycle/runtime support
- `crates/derive` — `#[ability]` macro
- `native_ability` — ArkTS package source shared by Rust and C/SDL native modules
- `package` — packaged ohpm artifact source
- `demo` — unified Harmony demo project
- `rust_example/demo_native` — unified native demo implementation

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

  async onCreate(
    want: Want,
    launchParam: AbilityConstant.LaunchParam
  ): Promise<void> {
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

## License

[MIT](./LICENSE)
