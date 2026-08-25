# openharmony-ability

## Introduce

openharmony-ability is the Rust runtime crate in this repository. It provides lifecycle and runtime helpers for OpenHarmony/HarmonyNext native applications.

## Runtime Context

`NativeAbility` opens the module/session bridge and passes the ArkTS init context into native code before any component render. In the Rust runtime, `OpenHarmonyApp` can read `moduleName`, `basePath`, `prefPath`, and `preferredLocales` via `init_context()`, `module_name()`, `base_path()`, `pref_path()`, and `preferred_locales()`. The Harmony `resourceManager` is a plugin capability: the `ResourceBridgePlugin` registered in the current bridge registry owns its native pointer. Access it through the `ResourceExt` extension trait on `OpenHarmonyApp`.

## XComponent Input

`Event::Input` keeps the original key, mouse, and touch events and also exposes native ArkUI semantics:

- `InputEvent::AxisEvent` owns the horizontal and vertical delta reported for a mouse wheel,
  touchpad, or rotary axis. The callback-scoped ArkUI input pointer never escapes into application
  state.
- `InputEvent::GestureEvent` reports system-recognized tap, pan, and swipe gestures in parallel
  with raw touch delivery. Pan events include both cumulative offsets and per-callback deltas plus
  velocity, so rendering frameworks do not need to derive scrolling from XComponent touch points.

Gesture handles are owned by the active render and are detached and disposed with that render.

## License

This project is licensed under the [MIT license](https://github.com/harmony-contrib/openharmony-ability/blob/main/LICENSE)
