# openharmony-ability-plugin-webview

English | [简体中文](README.zh-CN.md)

`openharmony-ability-plugin-webview` is the Rust ArkWeb/WebView facade paired with
`@ohos-rs/ability-plugin-webview`. ArkTS owns `WebviewController`, ArkUI `FrameNode` and ArkWeb
delegates. Rust retains controller IDs, named N-API data and Rust-owned callback/protocol closures.

The plugin does not embed WebView in `DefaultXComponent`. By default its FrameNode mounts
full-screen in the native module's single component root. Use `parent_node(handle)` to mount
under an `ohos.node` container and compose WebView, XComponent and custom ArkUI nodes.

## Contract

| Field | Value |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-webview` |
| ArkTS HAR | `@ohos-rs/ability-plugin-webview` |
| Plugin ID | `ohos.webview` |
| Execution | `AsyncBridge` / `invokeAsync` |
| Required context | `ui-context` |
| Mount | Current module/component root, full-screen by default; optional `parentHandle` for an `ohos.node` container |
| Core actions | `create`, controller operations, `evaluate-script` |

Outbound actions and inbound ArkWeb events use named N-API contracts, without JSON.
`create` returns a controller ID; use `WebviewHandle` rather than keeping ArkTS objects across threads.

## Integration and registration

Register the Rust facade during `#[ability]` initialization. Register custom schemes through
`WebviewProtocol::register` before initializing the Web engine:

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_webview::{
    WebviewBridgePlugin, WebviewProtocol, WebviewProtocolOptions,
};

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    WebviewProtocol::register("asset", WebviewProtocolOptions::Standard)
        .expect("scheme must be declared before Web engine initialization");
    app.register_plugin(WebviewBridgePlugin::new())
        .expect("webview facade must be registered once");
}
```

Add the HAR to `oh-package.json5` and create fresh instances through `LazyPlugin`:

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { WebviewPlugin } from "@ohos-rs/ability-plugin-webview";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new WebviewPlugin())];
}
```

See the [ArkTS README](../../plugins/webview/README.md) for runtime, mounting and delegate details.

## Creating and controlling WebViews

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_webview::{WebviewCreateRequest, WebviewExt};

async fn open_article(app: &OpenHarmonyApp) -> Result<()> {
    let client = app.webview()?;
    let handle = client
        .create(
            WebviewCreateRequest::new("article")
                .transparent(true)
                .url("https://example.com"),
        )
        .await?;

    handle.set_visible(true).await?;
    let title = handle.evaluate_script("document.title").await?;
    tracing::info!(?title, "page title");
    Ok(())
}
```

To compose a Rust-side node tree, create an `ohos.node` container, mount the WebView beneath it,
then mount the container into the root:

```rust
use napi_ohos::Result;
use openharmony_ability::{NodeExt, OpenHarmonyApp};
use openharmony_ability_plugin_webview::{WebviewCreateRequest, WebviewExt};

async fn composed_webview(app: &OpenHarmonyApp) -> Result<()> {
    let container = app.node()?.create_container().await?;
    app.webview()?
        .create(
            WebviewCreateRequest::new("article")
                .parent_node(container)
                .url("https://example.com"),
        )
        .await?;
    app.node()?.mount_into_root(container).await?;
    Ok(())
}
```

`WebviewCreateRequest` supports URL/HTML, parent-node composition, styles, JavaScript, DOM storage,
devtools, user agent, autoplay, document-start scripts, headers and transparency.
With `transparent(true)`, ArkTS uses a transparent background unless an explicit background
color overrides it.

`WebviewHandle` offers `set_visible`, `set_background_color`, `load_url`,
`load_url_with_headers`, `load_html`, `url`, `set_zoom`, `reload`, `focus`, `cookies_with_url`,
`clear_all_browsing_data`, `remove`/`dispose` and `evaluate_script` as async controller actions.

## Mounting and lifecycle

- One `DefaultXComponent` uses one native module; a second component in another window needs
  another module. Creation requests do not accept window/surface keys.
- A module/component can host multiple WebViews with distinct IDs, mount keys and controllers.
  Recreating the same ID replaces its previous instance. IDs are module-local; ArkTS generates
  process-unique internal controller tags to avoid cross-module collisions.
- Default mounting fills the current component root. Use `parent_node(container)` for composition;
  Rust decides whether to mount that container into the root.
- Async creation waits for controller attachment and initial navigation to start, driven by
  lifecycle/cancellation rather than fixed polling timers.
- On UI/Ability teardown, timeout or cancellation, ArkTS removes temporary nodes/controller
  mappings. Rust retains no `UIContext`, `FrameNode`, `WebviewController` or ArkTS function.

## WebView callbacks

Declare callbacks before creation with the module-local WebView ID:

```rust
use openharmony_ability_plugin_webview::{
    WebviewCallbacksBuilder, WebviewDownloadStartResponse,
};

WebviewCallbacksBuilder::new("article")
    .on_navigation_request(|request| request.url.starts_with("app://blocked"))
    .on_download_start(|request| WebviewDownloadStartResponse::allow(request.temp_path))
    .on_download_end(|event| tracing::info!(?event, "download completed"))
    .on_title_change(|event| tracing::info!(?event, "title changed"))
    .build()?;
```

ArkTS receives only the subscription snapshot; closures stay in Rust.
Navigation defaults to `intercept = false` when unsubscribed or failed (fail-open).
An unsubscribed download-start callback cancels the download (fail-closed).
Download-end/title callbacks are notifications. Events include an internal `native_tag`;
the facade checks that it still identifies the current controller, rejecting delayed events
from a replaced same-ID instance. Callbacks run inside the current N-API callback and must
return quickly. Copy owned data to workers for expensive work.

`ui-context-destroy`/`ability-destroy` clears attachment/tag state while preserving callback,
protocol and proxy declarations for later appearance. Cleanup does not depend on successful
ArkTS-to-Rust notifications during closing.

## Custom protocols and page JavaScript

Custom URL schemes and JavaScript proxies are separate mechanisms:

```rust
use std::borrow::Cow;
use openharmony_ability_plugin_webview::{
    WebviewJavascriptProxyBuilder, WebviewProtocol, WebviewProtocolOptions,
};

// During #[ability] initialization:
WebviewProtocol::register("asset", WebviewProtocolOptions::Standard)?;

// Before create:
client.custom_protocol("article", "asset", |_url, _request, _is_main_frame| {
    http::Response::builder()
        .header("content-type", "text/html")
        .body(Cow::Borrowed(&b"<h1>local page</h1>"[..]))
        .ok()
})?;

WebviewJavascriptProxyBuilder::new("article", "native")
    .add_method("postMessage", |_tag, arguments| {
        tracing::info!(?arguments, "page message");
    })
    .build()?;
```

New scheme declarations must precede process-wide engine initialization.
Native modules have independent Rust state but share ArkWeb. Before the first WebView initializes
the engine, all active matching modules flush their declarations.
Identical scheme/options declarations are idempotent across Ability recreation.
Modules loaded after engine startup may reuse only already-registered schemes with identical
options; they cannot add schemes. Declare per-ID handlers and proxies before creation.
After controller attachment, the plugin installs protocol/proxy/delegate bindings before
initial navigation. Use `custom_protocol_async`/`WebviewProtocolResponder` for async responses.

See the [plugin development standard](../../docs/plugin-development-standard.md) for type names,
reverse events, threading, mounting and acceptance rules.

## Document-start scripts

Document-start scripts use the declarative `Web.runJavaScriptOnDocumentStart`
attribute on API 15 and newer. The builder selects the API using the device's
`sdkApiVersion`; it does not depend on `AttributeModifier` support for Web-specific
methods. Compile with an SDK that includes API 15 or newer; the minimum supported
runtime remains API 12.

Each array entry remains a separate script with its own URL rules and runs in
array order, so an exception in one entry does not prevent the following entries
from running. On API 12–14, the original declarative `javaScriptOnDocumentStart`
attribute is retained and scripts still execute in lexicographic order. Ordered
execution is only guaranteed on API 15 and newer.

Both direct and drag-overlay WebViews configure the scripts before registering
the controller-attached callback that starts the first navigation. Both retain
the scripts supplied by `keySynthesisScripts`, including the main-window keyboard
shim; drag callbacks remain on the Web node in direct mode and on the separate
Stack in overlay mode.

## Native-tree embedding

Register `WebviewBridgePlugin::new()` and select `let client = app.webview()?.native()?`.
Declare native callbacks with `client.callbacks(id)` and JavaScript proxies with
`client.javascript_proxy(id, object)`; custom protocols declared on that client use
its registered plugin owner. Legacy builder signatures retain their existing scope.
Call `client.create_native(target_id, CreateRequest, NativeWebviewSettings)` to embed
in a Rust-owned node tree. `CreateRequest` owns the initial JavaScript, user agent
and document-start scripts; native settings add scrolling, page-end script and
inline HTML base URL. `handle.update_document_options(WebviewDocumentOptionsRequest)`
updates the same controller without replacing its navigation history.

`NativeWebviewEvents::new(&app, id, target_id, callback)` belongs to that registered
plugin instance and rejects stale controller generations. Attachment installs
protocol/proxy/callback declarations before first navigation, even without an event
subscriber. Native creation/removal is serialized per ID. Closing retires native
edges and controller registrations synchronously; disposal awaits page tasks and
preserves any owner whose retirement fails.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
