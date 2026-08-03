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

The generated `init(context)` forwards ArkTS init data into native code. Read it through
`app.init_context()`, `app.module_name()`, `app.base_path()`, `app.pref_path()`, and
`app.preferred_locales()`. The resource manager is available through
`openharmony_ability::resource_manager()` or `app.resource_manager()`.
