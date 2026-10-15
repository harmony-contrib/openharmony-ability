# openharmony-ability-derive

[English](README.md) | 简体中文

`#[ability]` 为一个 OpenHarmony native Ability module 生成 N-API 导出，包括生命周期初始化、
XComponent 渲染入口、返回键回调和通用桥接事件入口。

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

宏不接受参数。插件化架构已移除 `#[ability(webview)]` 和 `#[ability(protocol = ...)]`。
通过 Rust facade 与 ArkTS HAR factory 组合 WebView 和其他平台能力，不再将其作为框架渲染模式。
自定义 protocol 通过 `openharmony_ability_plugin_webview::WebviewProtocol` 和
`WebviewClient::custom_protocol` 接入，不恢复宏分支。

生成的 `render(slot, render_owner)` 为 Rust `RootNode` 标记当前组件 appearance owner。
每个 native module 只能绑定一个活动 `DefaultXComponent`，主/子窗口组件使用不同 module。
`dispose_render(render_owner)` 防止旧 teardown 释放新 appearance；
`dispose_all_renders()` 是 WindowStage 销毁时的兜底。
相同 owner 也约束 surface、输入和 frame 回调，旧组件的延迟回调不能覆盖新组件的原生窗口、IME 或几何状态。

渲染前，`init(bindings, bridge_owner, context)` 先建立 Ability-session transport。
`dispose_bridge(bridge_owner)` 仅释放匹配 session，因此组件消失/重现不会禁用 Ability-only 插件，
旧 teardown 也不能清除替代 session。这些参数由 `NativeAbility` 驱动，不由业务直接调用。

`context` 把 ArkTS 初始化数据传入 native。使用 `app.init_context()`、`app.module_name()`、
`app.base_path()`、`app.pref_path()`、`app.preferred_locales()` 读取。
资源管理器属于插件能力：在 `#[ability]` 中注册
`openharmony_ability_plugin_resource::ResourceBridgePlugin::new()`，
再通过 `ResourceExt`（`app.resource_manager()`）读取。
ArkTS 对应安装 session-scoped 的
`new LazyPlugin(() => new ResourcePlugin())`。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
