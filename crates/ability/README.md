# openharmony-ability

## Introduce

openharmony-ability is a crate for the OpenHarmony/HarmonyNext ability. It provides a way to create an OpenHarmony/HarmonyNext application with rust.

## Runtime Context

`RustAbility` passes the ArkTS init context into Rust during `init(context)`. In Rust, `OpenHarmonyApp` can read `moduleName`, `basePath`, `prefPath`, and `preferredLocales` via `init_context()`, `module_name()`, `base_path()`, `pref_path()`, and `preferred_locales()`.

## License

This project is licensed under the [MIT license](https://github.com/harmony-contrib/openharmony-ability/blob/main/LICENSE)