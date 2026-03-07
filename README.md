# OpenHarmony Ability

> This project is in progress, and the API is not stable.

`openharmony-ability` provides Rust-side lifecycle management and ArkTS-side entry helpers for OpenHarmony applications, similar in spirit to `android-activity`.

## Architecture

OpenHarmony applications are driven by callbacks, so there are two important constraints:

1. Do not block the main thread.
2. `run_loop` does not retain user resources for you, so resources that must outlive setup need stable ownership.

![Architecture](/fixtures/openharmony-ability.png)

## Repository Layout

- `crates/ability` — Rust lifecycle/runtime support
- `crates/derive` — `#[ability]` macro
- `ability_rust` — ArkTS package source for `@ohos-rs/ability`
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

2. Implement your native entry:

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

3. Use `RustAbility` in ArkTS:

```ts
import { RustAbility } from "@ohos-rs/ability";
import Want from "@ohos.app.ability.Want";
import { AbilityConstant } from "@kit.AbilityKit";

export default class EntryAbility extends RustAbility {
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
- Native demo module: `rust_example/demo_native/src/lib.rs`
- ArkTS package source: `ability_rust`

## License

[MIT](./LICENSE)
