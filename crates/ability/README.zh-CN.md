# openharmony-ability

[English](README.md) | 简体中文

## 简介

`openharmony-ability` 是本仓库的 Rust runtime crate，为 OpenHarmony/HarmonyNext native 应用提供生命周期和运行时辅助能力。

## 运行时上下文

`NativeAbility` 在任何组件渲染前打开 module/session 桥接，并向 native 传入 ArkTS init context。
Rust 的 `OpenHarmonyApp` 通过 `init_context()`、`module_name()`、`base_path()`、`pref_path()`、
`preferred_locales()` 读取 `moduleName`、`basePath`、`prefPath`、`preferredLocales`。
Harmony `resourceManager` 属于插件能力：当前 registry 注册的 `ResourceBridgePlugin` 持有 native
指针，应用通过 `OpenHarmonyApp` 上的 `ResourceExt` 访问。

## XComponent 输入

`Event::Input` 区分原始 XComponent 输入与 Rust 自有的 ArkUI 语义事件：

- `InputEvent::XComponent` 包含原始按键、鼠标和可选触摸事件。
- `InputEvent::ArkUi` 包含独立持有数据的轴事件与系统识别手势。callback 范围内的 ArkUI 指针不会逃逸到业务状态；
  每个事件快照包括位置、设备/工具信息、时间戳、触点数和主指针 ID。
- 渲染前通过 `OpenHarmonyApp::set_touch_input_delivery` 选择原始触摸、ArkUI 手势或两者。
  鼠标/按键与轴事件投递独立于触摸选择。

Pan 事件提供累计偏移、每次回调的增量和速度，渲染框架无需自行从原始触点识别手势。

手势 handle 由活动 render 持有，随 render 一起移除和释放。

## 可选鼠标、键盘与拖放支持

默认 feature 提供原始 XComponent 键盘和指针输入。`mouse` 转发
`ohos-xcomponent-binding/api-18`，通过
`openharmony_ability::xcomponent::MouseAction::Cancel` 暴露原生鼠标取消事件。
它为显式启用项，不会同时启用 `keyboard`、`stylus` 或 `drag`。
使用重导出的类型即可，无需直接依赖 binding：

```toml
openharmony-ability = { version = "1.0.0-beta.3", features = ["mouse"] }
```

通过 `keyboard` 显式启用增强 ArkUI 键盘输入：

```toml
openharmony-ability = { version = "1.0.0-beta.3", features = ["keyboard"] }
```

`keyboard` enables `KeyboardInputDelivery::ArkUi`, `KeyboardEventData`,
`KeyboardEventResponse` and `ArkUiInputEvent::Key` through API 14/15; it is not a
default feature. Select ArkUI delivery before rendering. Each physical transition
arrives once with `ime_consumed`: update held-key state for every key, but never
execute consumed keys as shortcuts or hardware text. Input and wakes share the
UI-thread FIFO; remove timestamp deduplication. `api-19` opts into API-19 lock
snapshots.

The breaking contract removes `KeyPreIme` and `ArkUiWithTextInput`. Configure
API-26 native key consumption explicitly through `with_ime_for` and `api-26`
before attachment. `TextInputReadyChanged` reports editor lifetime independently
of EGL readiness.

原生文件拖放也需显式启用：

```toml
openharmony-ability = { version = "1.0.0-beta.3", features = ["drag"] }
```

`drag` 提供 `ArkUiInputEvent::Drag`、`DragInputData`、`DragPhase`、
`DragResponse`、`NativeFileDrag`，注册原生拖放回调，并启用 ArkUI UDMF/image bindings。
它不在默认 feature 中。

`NativeFileDrag::node_handle` 返回具名 XComponent view。在源 surface 存活时取得它，
再释放 surface 锁后调用 `start`，因为启动原生拖放可能同步重入输入分发。
保持源 surface 存活至操作结束，并在释放 surface 前 drop drag。
binding 负责 action 释放、监听移除，以及数据与预览的生命周期。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
