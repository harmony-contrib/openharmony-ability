# @ohos-rs/ability

`@ohos-rs/ability` provides ArkTS-side helpers for loading Rust native modules and forwarding OpenHarmony lifecycle events into Rust.

## Install

```bash
ohpm install @ohos-rs/ability
```

## API

### `RustAbility`

`RustAbility` wraps `UIAbility` and initializes one or more Rust native modules.

```ts
import { RustAbility } from "@ohos-rs/ability";

export default class EntryAbility extends RustAbility {
  public moduleName: string = "demo_native";

  onCreate() {
    super.onCreate();
  }
}
```

Notes:

1. Every lifecycle override should call the `super` implementation first.
2. `moduleName` is the bare module name; the runtime resolves it to `lib<moduleName>.so`.
3. `moduleName` can also be `string[]` when one ability needs multiple native modules.

### `loadMode`

Controls how the native module is loaded.

- `async` — uses dynamic import and is the default
- `sync` — uses `loadNativeModule`

When using `sync`, add the corresponding library to `build-profile.json5` runtime packages.

### `DefaultXComponent`

`DefaultXComponent` loads the native module and binds the default Rust rendering surface.

```ts
import { DefaultXComponent } from "@ohos-rs/ability";

@Entry
@Component
struct Index {
  build() {
    Row() {
      Column() {
        DefaultXComponent({ moduleName: "demo_native" })
      }
      .width("100%")
    }
    .height("100%")
  }
}
```

### Custom Page Example

```ts
import { RustAbility } from "@ohos-rs/ability";
import Want from "@ohos.app.ability.Want";
import { AbilityConstant } from "@kit.AbilityKit";
import window from "@ohos.window";

export default class EntryAbility extends RustAbility {
  public moduleName: string = "demo_native";
  public defaultPage: boolean = false;

  async onCreate(
    want: Want,
    launchParam: AbilityConstant.LaunchParam
  ): Promise<void> {
    super.onCreate(want, launchParam);
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    super.onWindowStageCreate(windowStage);
    await windowStage.loadContent("pages/Index");
  }
}
```
