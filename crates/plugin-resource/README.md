# openharmony-ability-plugin-resource

English | [简体中文](README.zh-CN.md)

`openharmony-ability-plugin-resource` exposes HarmonyOS resource access to Rust, paired with
`@ohos-rs/ability-plugin-resource`. The ArkTS wrapper pushes the platform object in its
Ability-scoped `onInstall`; Rust converts it to a native pointer within that N-API callback and
stores it on the matching registry's `ResourceBridgePlugin` instance. Subsequent raw-file,
media and drawable reads use `ohos-resource-manager-binding` and the OpenHarmony C API directly.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-resource` |
| ArkTS HAR | `@ohos-rs/ability-plugin-resource` |
| Plugin ID | `ohos.resource` |
| Execution | `AsyncBridge` / `invokeAsync` (no outbound actions) |
| Required context | `ability` |
| Inbound event | `resource-manager-ready`: `ohos.resource.ResourceManagerRef` (the platform object) → `ohos.resource.ResourceManagerReadyResponse { accepted }` |

`ResourceManagerRef` is inbound-only. Decoding immediately invokes
`OH_ResourceManager_InitNativeResourceManager` to obtain `NonNull<NativeResourceManager>`;
no ArkTS object reference is retained across threads.

## Integration

1. Add the crate and register it in the `#[ability]` initializer:

   ```rust
   use openharmony_ability::OpenHarmonyApp;
   use openharmony_ability_derive::ability;
   use openharmony_ability_plugin_resource::{ResourceBridgePlugin, ResourceExt};

   #[ability]
   fn configure_ability(app: OpenHarmonyApp) {
       app.register_plugin(ResourceBridgePlugin::new())
           .expect("resource Rust facade must be registered exactly once");
   }
   ```

2. Create a separate ArkTS wrapper for each host/session; the matching Rust registry instance
   owns the native pointer:

   ```ts
   import { LazyPlugin } from "@ohos-rs/ability";
   import { ResourcePlugin } from "@ohos-rs/ability-plugin-resource";

   // in NativeAbility subclass:
   public bridgePlugins = [
     new LazyPlugin(() => new ResourcePlugin()),
   ];
   ```

3. Read resources from application code:

   ```rust
   use openharmony_ability_plugin_resource::ResourceExt;

   if let Some(manager) = app.resource_manager() {
       let dir = manager.open_dir("");
       // ...
   }
   ```

## Timing

The push occurs in `onInstall`, after the inbound event sink is attached and Rust receives
`AbilityCreated`. It needs neither WindowStage nor DefaultXComponent. Ability-only plugins
can receive events before rendering; UI plugins such as WebView still wait for their contexts.

## Thread safety

Native resource-manager reads are not thread-safe, as documented by
`ohos-resource-manager-binding`. A `ResourceManager` can be cloned across threads, but callers
must serialize concurrent reads (for example with `Mutex<ResourceManager>`).
Ability reconstruction clears the old manager before accepting the new wrapper's handle.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
