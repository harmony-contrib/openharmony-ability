# OpenHarmony Ability

> This project is in progress, and the API is not stable.

`openharmony-ability` is the native integration layer for OpenHarmony applications. It combines Rust-side runtime crates with ArkTS-side entry helpers such as `NativeAbility`, similar in spirit to [android-activity](https://github.com/rust-mobile/android-activity).

## Architecture

The architecture of OpenHarmony is similar to Node.js, where we need to manage the application's lifecycle via callbacks. Hence, there are a few key points to keep in mind.

1. Don't block the main thread as it can lead to application freezing and crashing.
2. openharmony-ability's run_loop doesn't retain the resource and ownership, so if you create a new resource, you should leak it to prevent NULL pointer.

![Architecture](/fixtures/openharmony-ability.png)

We provide packages and crates to help you build OpenHarmony applications with native code, including Rust integrations and shared ArkTS entry helpers for C/SDL-style modules.

### ArkTS

We need a entry-point to start the application, and we use ArkTS to manage the application's lifecycle.

- [@ohos-rs/ability](../package/README.md)  
  All of ability need to extend `NativeAbility` and all lifecycle need to call `super.xx` to make sure the ability can work normally.

### Rust Runtime

- [openharmony-ability](../crates/ability/README.md)  
  Basic crate to manage the application's lifecycle.

- [openharmony-ability-derive](../crates/derive/README.md)  
  Macro to generate the ability's implementation.

## Usage

1. use `ohrs` to init project and add `openharmony-ability` dependencies.

   ```bash
   ohrs init hello

   cargo add openharmony-ability
   cargo add openharmony-ability-derive
   ```

2. Add the follow code to `lib.rs`.

   ```rust
   use ohos_hilog_binding::hilog_info;
   use openharmony_ability::App;
   use openharmony_ability_derive::ability;

   #[ability]
   fn openharmony_app(app: App) {
       app.run_loop(|types| {
           hilog_info!(format!("ohos-rs macro: {:?}", types.as_str()).as_str());
       });
   }
   ```

   > Note: `ohos_hilog_binding` is a optional dependency and you can add or remove it.

3. Add `@ohos-rs/ability` to your `OpenHarmony/HarmonyNext` project.

   ```bash
   ohpm install @ohos-rs/ability
   ```

4. change the `EntryAbility.ets` file to the follow code:

   ```ts
   import { NativeAbility } from "@ohos-rs/ability";
   import Want from "@ohos.app.ability.Want";
   import { AbilityConstant } from "@kit.AbilityKit";

   export default class EntryAbility extends NativeAbility {
     public moduleName: string = "example";

     async onCreate(
       want: Want,
       launchParam: AbilityConstant.LaunchParam
     ): Promise<void> {
       // Note: you should call super.onCreate to make sure the ability can work normally.
       super.onCreate(want, launchParam);
     }
   }
   ```

5. Set `moduleName` to the bare module name, for example `hello`. The framework will load `libhello.so` internally. You can also pass `string[]` when one ability needs to initialize multiple native modules.

6. Build your native project and copy the dynamic library to your (Open-)Harmony(Next) project. The example below uses Rust, but the ArkTS `NativeAbility` entry is also reusable for C/SDL-style native modules that expose the same contract.

7. Now, you can enjoy it.

## Example

- Unified native example: `../rust_example/demo_native/src/lib.rs`
