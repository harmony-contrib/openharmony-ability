# openharmony-ability-derive

`#[ability]` generates the N-API exports for one OpenHarmony native Ability module: lifecycle
initialization, XComponent render entry, back-press callback, and the generic bridge event ports.

```rust
use openharmony_ability::{Event, OpenHarmonyApp};
use openharmony_ability_derive::ability;

#[ability]
fn openharmony_app(app: OpenHarmonyApp) {
    app.run_loop(|event| match event {
        Event::WindowRedraw(_) => {}
        _ => {}
    });
}
```

The macro accepts no arguments. In particular, `#[ability(webview)]` and
`#[ability(protocol = ...)]` were removed in the pluginized architecture. Compose WebView and
other platform capabilities through their Rust facade crate and ArkTS HAR factory instead of
making them framework render modes. A business that needs custom protocol interception must ship
it through `openharmony-ability-plugin-webview::WebviewProtocol` and
`WebviewClient::custom_protocol` rather than restoring a macro branch.

The generated `render(slot, render_owner)` export tags the Rust `RootNode` with its
component appearance owner. A native module may have only one attached `DefaultXComponent`; main
and sub-window components use different modules. The matching `dispose_render(render_owner)`
prevents stale teardown from releasing a newer appearance; `dispose_all_renders()` is the
WindowStage-destroy fallback. The same owner gates Rust surface, input and frame callbacks, so a
delayed callback from an old component cannot overwrite a replacement component's raw window,
IME or geometry state.

Before that optional render, generated `init(bindings, bridge_owner, context)` opens the native
module's Ability-session transport. Generated `dispose_bridge(bridge_owner)` releases only the
matching session, so component disappear/reappear does not disable ability-only plugins and stale
teardown cannot clear a replacement session. These transport arguments are driven by
`NativeAbility`; applications do not call them directly.

The `context` argument forwards ArkTS init data into native code. Read it through
`app.init_context()`, `app.module_name()`, `app.base_path()`, `app.pref_path()`, and
`app.preferred_locales()`. The resource manager is a plugin capability: register
`openharmony_ability_plugin_resource::ResourceBridgePlugin::new()` in the `#[ability]` initializer and
read it via the `ResourceExt` trait (`app.resource_manager()`); the ArkTS side must install
`@ohos-rs/ability-plugin-resource` as a session-scoped `new LazyPlugin(() => new ResourcePlugin())`.
