# @ohos-rs/ability

[English](README.md) | 简体中文

`@ohos-rs/ability` 是加载 native module、转发 OpenHarmony 生命周期和承载通用桥接插件的 ArkTS runtime。
权限、窗口、退出和 WebView 等具体能力位于独立 HAR 中，core 不包含这些专用 helper。

## Install

```bash
ohpm install @ohos-rs/ability
```

## API

### `NativeAbility`

`NativeAbility` 封装 `UIAbility`，初始化一个或多个 native module：

```ts
import { NativeAbility } from "@ohos-rs/ability";
import Want from "@ohos.app.ability.Want";
import { AbilityConstant } from "@kit.AbilityKit";

export default class EntryAbility extends NativeAbility {
  public moduleName: string = "demo_native";

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onCreate(want, launchParam);
  }
}
```

说明：

1. 重写生命周期时应先调用 `super`。
2. `moduleName` 为裸模块名，runtime 解析为 `lib<moduleName>.so`。
3. 同一 Ability 需要多个 native module 时，可使用 `string[]`。
4. 每个 `DefaultXComponent` 使用一个独立 module；同一 module 不能同时绑定两个组件或两个活动 Ability session。
5. module bridge 在 `NativeAbility.onCreate` 期间建立，独立于可选组件渲染。
   Ability-only 插件可在组件 appearance 前和消失/重现期间工作；UI 插件仍需等待 `ui-context-ready`。

### `loadMode`

控制 native module 加载方式：

- `async` — 默认使用动态 import
- `sync` — 使用 `loadNativeModule`

使用 `sync` 时，在 `build-profile.json5` 的 runtime packages 中声明对应动态库。

### `DefaultXComponent`

`DefaultXComponent` 加载一个 native module，绑定渲染 surface，并持有该 module 的单一节点树。
一个 Ability 可以声明多个 module，在一个或多个窗口放置多个组件，每个组件使用不同 module。
同一 module 的第二次并发组件绑定会被拒绝。

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

### 插件与 module 节点树

在 `NativeAbility.bridgePlugins` 中显式组合 ArkTS factory。
需要 UI 节点的能力通过 `context.appendChild` 把 `FrameNode` 挂进 module/component 根树；
框架不内置 WebView 特例。Rust 使用不透明 `ohos.node` handle 组合节点，
`FrameNode` 不跨 N-API。一个组件可以按 controller ID 和 mount key 区分多个 WebView。

`WindowStage` 生命周期仍是 Ability 级。窗口 size、rect、avoid-area 和 keyboard 事件则按组件实际
`UIContext` 对应的 `Window` 路由，仅转发到该组件的 native module，
子窗口 module 不会误收主窗口几何信息。

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

### 具名桥接值

ArkTS 插件接收具有稳定类型名的真实 N-API value，不使用强制 JSON envelope。
在能力边界检查类型名，并返回约定的 response 类型名。

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

`std.string`、`std.bytes` 是内置名称。业务 `#[napi(object)]` 结构体通过
Rust `impl_bridge_napi_type!(Type, "name")` 明确声明契约。桥接层没有 JSON transport 类型。

### 自定义页面示例

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

OpenHarmony 不会等待 `onCreate` 或 `onWindowStageCreate`。
自定义页面应重写上述框架 hook，它运行在串行且检查 generation 的 WindowStage 事务中。
将平台回调本身声明为 `async` 不能建立时序屏障，可能导致
`DefaultXComponent` 在 bridge session 存在前渲染。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
