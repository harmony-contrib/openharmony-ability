# openharmony-ability-plugin-resource

`openharmony-ability-plugin-resource` 是 HarmonyOS `resourceManager` 能力的 Rust facade。它与
ArkTS HAR `@ohos-rs/ability-plugin-resource` 成对使用：ArkTS wrapper 持有平台对象并在 `ui-context-ready`
时经入站事件推送给 Rust，Rust 在同一 N-API callback 内把对象转成 native 指针存全局；之后所有
读取（raw file、media、drawable 等）通过 `ohos-resource-manager-binding` 直连 OpenHarmony C API，
不经过 ArkTS。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-resource` |
| ArkTS HAR | `@ohos-rs/ability-plugin-resource` |
| 插件 ID / bridge 版本 | `ohos.resource` / `1` |
| 执行模式 | 异步（`AsyncBridge` / `invokeAsync`，无出站 action） |
| 前置 context | `ability` |
| 入站事件 | `resource-manager-ready`：`ohos.resource.ResourceManagerRef`（ArkTS 直接传 `resourceManager` 对象）→ `ohos.resource.ResourceManagerReadyResponse { accepted }` |

`ResourceManagerRef` 是 inbound-only 类型：解码时立即调用
`OH_ResourceManager_InitNativeResourceManager` 转成 `NonNull<NativeResourceManager>`，绝不保留
ArkTS 对象引用跨线程。

## 接入

1. 在 native Rust 模块中添加该 crate，并在 `#[ability]` 初始化器内注册 Rust facade：

   ```rust
   use openharmony_ability::OpenHarmonyApp;
   use openharmony_ability_derive::ability;
   use openharmony_ability_plugin_resource::{ResourceBridgePlugin, ResourceExt};

   #[ability]
   fn configure_ability(app: OpenHarmonyApp) {
       app.register_plugin(ResourceBridgePlugin)
           .expect("resource Rust facade must be registered exactly once");
   }
   ```

2. ArkTS 侧为每个 module/session 创建独立 wrapper；进程级 native pointer 由 Rust 持有：

   ```ts
   import { LazyPlugin } from "@ohos-rs/ability";
   import { ResourcePlugin } from "@ohos-rs/ability-plugin-resource";

   // in NativeAbility subclass:
   public bridgePlugins = [
     new LazyPlugin(() => new ResourcePlugin()),
   ];
   ```

3. 业务侧读取：

   ```rust
   use openharmony_ability_plugin_resource::ResourceExt;

   if let Some(manager) = app.resource_manager() {
       let dir = manager.open_dir("");
       // ...
   }
   ```

## 时序说明

推送发生在 `ability-create`：入站事件 sink 在 `NativeAbility.onCreate` 中 `module.init` 之后立即
attach（不依赖 UI 渲染），Rust registry 也在 `ability-create` 事件到达 ArkTS 插件之前已经收到
`AbilityCreated`。因此只依赖 `ability` 的插件可以在渲染前收到入站事件；需要 `ui-context` 的插件
（如 webview）仍按其自身 requires 等到对应上下文就绪。

## 线程安全

`NativeResourceManager` 的读取方法本身**非线程安全**（`ohos-resource-manager-binding` 文档
明确说明）。`ResourceManager` 可跨线程 Clone，但并发读取需要调用方自行串行化（例如
`Mutex<ResourceManager>`）——这与插件化之前的全局单例语义一致。
