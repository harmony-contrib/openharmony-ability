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
4. Each `DefaultXComponent` uses exactly one distinct module. A module cannot be attached to two
   components or two active Ability sessions at the same time.
5. The module bridge transport is opened during `NativeAbility.onCreate`, independently from its
   optional component render. Ability-only plugins therefore work before appearance and across a
   component disappear/reappear cycle; UI plugins still wait for `ui-context-ready`.

### `loadMode`

Controls how the native module is loaded.

- `async` — uses dynamic import and is the default
- `sync` — uses `loadNativeModule`

When using `sync`, add the corresponding library to `build-profile.json5` runtime packages.

### `DefaultXComponent`

`DefaultXComponent` loads one native module, binds its rendering surface, and owns that module's
single node tree. An Ability can place several components in one or several windows by declaring
several modules and assigning a different module to each component. A module's second concurrent
component attachment is rejected.

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

### Plugins and module-owned node trees

Compose ArkTS plugin factories explicitly in `NativeAbility.bridgePlugins`. A capability that
needs UI nodes mounts a `FrameNode` into its module's component root (`context.appendChild`); the
framework never embeds a WebView special case. Rust composes trees through opaque `ohos.node`
handles; `FrameNode` values never cross the N-API boundary. One component may host multiple
WebViews, distinguished by controller ID and mount key.

`WindowStage` lifecycle remains Ability-wide. Window size, rect, avoid-area and keyboard events do
not: each component host resolves the actual `Window` from its `UIContext` and forwards those
events only to that component's native module. A sub-window module therefore never receives main
window geometry by mistake.

```ts
import { DefaultXComponent, LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { WebviewPlugin } from "@ohos-rs/ability-plugin-webview";

export default class EntryAbility extends NativeAbility {
  public moduleName = ["demo_native", "demo_sub_native"];
  public bridgePlugins = [new LazyPlugin(() => new WebviewPlugin())];
}

@Entry
@Component
struct Page {
  @Builder BusinessOverlay() {
    Text("business overlay")
  }

  build() {
    Stack() {
      // Each component uses a distinct module and owns an independent tree.
      DefaultXComponent({ moduleName: "demo_native" })
      DefaultXComponent({ moduleName: "demo_sub_native" })
      this.BusinessOverlay()
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
  // id/execution/requires omitted
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
import window from "@ohos.window";

export default class EntryAbility extends NativeAbility {
  public moduleName: string = "demo_native";
  public defaultPage: boolean = false;

  protected override async loadWindowStageContent(
    windowStage: window.WindowStage,
  ): Promise<void> {
    await windowStage.loadContent("pages/Index");
  }
}
```

OpenHarmony does not await `onCreate` or `onWindowStageCreate`. Override the framework hook above
for custom page loading; it runs inside the serialized, generation-checked WindowStage transaction.
Declaring the platform callback itself `async` is not an ordering barrier and can render
`DefaultXComponent` before its bridge session exists.
