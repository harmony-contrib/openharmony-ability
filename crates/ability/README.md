# openharmony-ability

English | [简体中文](README.zh-CN.md)

## Introduce

openharmony-ability is the Rust runtime crate in this repository. It provides lifecycle and runtime helpers for OpenHarmony/HarmonyNext native applications.

## Runtime Context

`NativeAbility` opens the module/session bridge and passes the ArkTS init context into native code before any component render. In the Rust runtime, `OpenHarmonyApp` can read `moduleName`, `basePath`, `prefPath`, and `preferredLocales` via `init_context()`, `module_name()`, `base_path()`, `pref_path()`, and `preferred_locales()`. The Harmony `resourceManager` is a plugin capability: the `ResourceBridgePlugin` registered in the current bridge registry owns its native pointer. Access it through the `ResourceExt` extension trait on `OpenHarmonyApp`.

## XComponent Input

`Event::Input` separates raw XComponent input from owned ArkUI semantics:

- `InputEvent::XComponent` contains the original key, mouse, and optionally touch events.
- `InputEvent::ArkUi` contains self-contained axis and system-recognized gesture events. The
  callback-scoped ArkUI pointer never escapes into application state; every event snapshots the
  pointer position, device/tool metadata, timestamp, contact count, and primary pointer ID.
- `OpenHarmonyApp::set_touch_input_delivery` selects raw XComponent touch, ArkUI gestures, or both
  before rendering. Mouse/key and axis delivery are independent of this touch-only selection.

Pan events include cumulative offsets, per-callback deltas, and velocity, so rendering frameworks
do not need to derive gesture recognition from XComponent touch points.

Gesture handles are owned by the active render and are detached and disposed with that render.

## Optional mouse, keyboard, and drag/drop support

Raw XComponent keyboard and pointer input are available with the default features.
The `mouse` feature forwards `ohos-xcomponent-binding/api-18`, exposing
`openharmony_ability::xcomponent::MouseAction::Cancel` for native mouse
cancellation. It is opt-in and does not enable `keyboard`, `stylus`, or `drag`.
Consumers can use the re-exported XComponent types without a direct binding dependency:

```toml
openharmony-ability = { version = "1.0.0-beta.3", features = ["mouse"] }
```

Enhanced ArkUI keyboard delivery is opt-in through the `keyboard` feature:

```toml
openharmony-ability = { version = "1.0.0-beta.3", features = ["keyboard"] }
```

`keyboard` enables `KeyboardInputDelivery::ArkUi`, `KeyboardEventData`,
`KeyboardEventResponse`, and `ArkUiInputEvent::{KeyPreIme, Key}`. It forwards
`ohos-arkui-binding/api-19` and is not part of the default feature set. The
default stream remains raw XComponent input; select
`OpenHarmonyApp::set_keyboard_input_delivery(KeyboardInputDelivery::ArkUi)`
before rendering to receive Unicode, held-key state, optional lock state, and
synchronous key consumption. Selecting ArkUI delivery on a runtime below API 19
returns an error. Enabling `drag` does not enable `keyboard`.

**Migration:** applications enabling `keyboard` must target API 19 or later.
Applications supporting older systems can leave it disabled and retain raw
XComponent key delivery.

Native file drag/drop is opt-in:

```toml
openharmony-ability = { version = "1.0.0-beta.3", features = ["drag"] }
```

The `drag` feature enables `ArkUiInputEvent::Drag`, `DragInputData`, `DragPhase`,
`DragResponse` and `NativeFileDrag`, registers native drag/drop callbacks, and enables
the ArkUI UDMF/image bindings. It is not part of the default feature set.

`NativeFileDrag::node_handle` returns a typed XComponent view. Capture it while the
source surface is retained, then release the surface lock before `start`: starting
a native drag can synchronously reenter input dispatch. Keep the source surface
alive until completion, and drop the drag before releasing the surface. The binding
owns native action disposal, listener removal, data and preview lifetimes.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
