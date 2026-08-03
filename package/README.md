# @ohos-rs/ability

`@ohos-rs/ability` provides the ArkTS-side runtime for loading native modules, forwarding
OpenHarmony lifecycle events, and hosting generic bridge plugins. Concrete capabilities live in
separate HAR packages; the core package does not contain permission, window, exit, or WebView
helpers.

## Install

```bash
ohpm install @ohos-rs/ability
```

## API

### `NativeAbility`

`NativeAbility` wraps `UIAbility` and initializes one or more native modules.

```ts
import { NativeAbility } from "@ohos-rs/ability";

export default class EntryAbility extends NativeAbility {
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

`DefaultXComponent` loads the native module and binds the default native rendering surface. It
also exposes the generic `xcomponent-overlay` node slot for capability plugins.

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

### Plugins and node slots

Compose ArkTS plugin factories explicitly in `NativeAbility.bridgePlugins`. A capability that
needs UI nodes mounts a `FrameNode` into a generic slot; the framework never embeds a WebView
special case.

```ts
import { BridgeNodeHost, DefaultXComponent, NativeAbility } from "@ohos-rs/ability";
import { createWebviewPlugin } from "@ohos-rs/plugin-webview";

export default class EntryAbility extends NativeAbility {
  public moduleName = "demo_native";
  public bridgePlugins = [createWebviewPlugin()];
}

@Entry
@Component
struct Page {
  @Builder BusinessOverlay() {
    Text("business overlay")
  }

  build() {
    Stack() {
      DefaultXComponent({ moduleName: "demo_native" })
      BridgeNodeHost({
        moduleName: "demo_native",
        slotId: "webview-panel",
        foreground: this.BusinessOverlay,
      })
    }
  }
}
```

### Typed bridge values

ArkTS plugins receive a real N-API value with a stable type name, rather than a mandatory JSON
envelope. Check the name at the capability boundary and return the declared response name.

```ts
import type { AsyncBridgePlugin, BridgeTypedValue } from "@ohos-rs/ability";

class ProfilePlugin implements AsyncBridgePlugin {
  // id/version/execution omitted
  async invokeAsync(_action: string, request: BridgeTypedValue): Promise<BridgeTypedValue> {
    if (request.typeName !== "account.Profile") {
      throw new Error("unexpected bridge type");
    }
    const profile = request.value as { userId: string; visits: number };
    return {
      typeName: "account.Profile",
      value: { userId: profile.userId, visits: profile.visits + 1 } as ESObject,
    };
  }
}
```

`std.string` and `std.bytes` are built-in names; application-owned `#[napi(object)]` structs use
an explicit Rust `impl_bridge_napi_type!(Type, "name")` contract. The bridge deliberately has no
JSON transport type.

### Custom Page Example

```ts
import { NativeAbility } from "@ohos-rs/ability";
import Want from "@ohos.app.ability.Want";
import { AbilityConstant } from "@kit.AbilityKit";
import window from "@ohos.window";

export default class EntryAbility extends NativeAbility {
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
