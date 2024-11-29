# OpenHarmony Ability

> This project is in progress, and the API is not stable.

`openharmony-ability` is a crate to manage openharmony applcation's activity with rust, be similar to [android-activity](https://github.com/rust-mobile/android-activity).

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
       super.onCreate(want, launchParam);
     }
   }
   ```

4. Change the `moduleName` to your rust project name. For example, we need to change it with `hello` in this project.

5. Build your rust project and copy the dynamic library to (Open-)Harmony(Next) project.

6. Now, you can enjoy it.
