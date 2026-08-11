# openharmony-ability

## Introduce

openharmony-ability is the Rust runtime crate in this repository. It provides lifecycle and runtime helpers for OpenHarmony/HarmonyNext native applications.

## Runtime Context

`NativeAbility` opens the module/session bridge and passes the ArkTS init context into native code before any component render. In the Rust runtime, `OpenHarmonyApp` can read `moduleName`, `basePath`, `prefPath`, and `preferredLocales` via `init_context()`, `module_name()`, `base_path()`, `pref_path()`, and `preferred_locales()`. The Harmony `resourceManager` is a plugin capability: the `ResourceBridgePlugin` registered in the current bridge registry owns its native pointer. Access it through the `ResourceExt` extension trait on `OpenHarmonyApp`.

## License

This project is licensed under the [MIT license](https://github.com/harmony-contrib/openharmony-ability/blob/main/LICENSE)
