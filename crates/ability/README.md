# openharmony-ability

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

## License

This project is licensed under the [MIT license](https://github.com/harmony-contrib/openharmony-ability/blob/main/LICENSE)
