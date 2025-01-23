# OpenHarmony Ability

> This project is in progress, and the API is not stable.

`openharmony-ability` is a crate to manage OpenHarmony application's activity with rust, be similar to [android-activity](https://github.com/rust-mobile/android-activity).

## Architecture

The architecture of OpenHarmony is similar to Node.js, where we need to manage the application's lifecycle via callbacks. Hence, there are a few key points to keep in mind.

1. Don't block the main thread as it can lead to application freezing and crashing.
2. openharmony-ability's run_loop doesn't retain the resource and ownership, so if you create a new resource, you should leak it to prevent NULL pointer.

![Architecture](/fixtures/openharmony-ability.png)

We provide some packages or crates to help you develop OpenHarmony application with Rust.

### ArkTS

We need a entry-point to start the application, and we use ArkTS to manage the application's lifecycle.

- @ohos-rs/ability
  All of ability need to extend `RustAbility` and all lifecycle need to call `super.xx` to make sure the ability can work normally.

### Rust
- openharmony-ability
  Basic crate to manage the application's lifecycle.

- openharmony-ability-derive
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

3. Add `@ohos-rs/ability` to your `(Open-)Harmony(Next)` project and change the `EntryAbility.ets` file to the follow code:

   ```ts
   import { RustAbility } from "@ohos-rs/ability";
   import Want from "@ohos.app.ability.Want";
   import { AbilityConstant } from "@kit.AbilityKit";

   export default class EntryAbility extends RustAbility {
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

4. Change the `moduleName` to your rust project name. For example, we need to change it with `hello` in this project.

5. Build your rust project and copy the dynamic library to (Open-)Harmony(Next) project.

6. Now, you can enjoy it.


## Example

See example with [example](./example/src/lib.rs)