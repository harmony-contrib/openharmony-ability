# openharmony-ability

## Introduce

openharmony-ability is the Rust runtime crate in this repository. It provides lifecycle and runtime helpers for OpenHarmony/HarmonyNext native applications.

## Runtime Context

`NativeAbility` passes the ArkTS init context into native code during `init(context)`. In the Rust runtime, `OpenHarmonyApp` can read `moduleName`, `basePath`, `prefPath`, and `preferredLocales` via `init_context()`, `module_name()`, `base_path()`, `pref_path()`, and `preferred_locales()`. The Harmony `resourceManager` is a plugin capability: the ArkTS wrapper `@ohos-rs/plugin-resource` pushes the platform object to the Rust facade `openharmony-ability-plugin-resource`, which stores a native pointer globally. Access it through `openharmony_ability_plugin_resource::resource_manager()` or the `ResourceExt` extension trait on `OpenHarmonyApp`.

## License

This project is licensed under the [MIT license](https://github.com/harmony-contrib/openharmony-ability/blob/main/LICENSE)
