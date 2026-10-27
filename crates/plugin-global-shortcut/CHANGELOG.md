# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.4](https://github.com/harmony-contrib/openharmony-ability/compare/openharmony-ability-plugin-global-shortcut-v1.0.0-beta.3...openharmony-ability-plugin-global-shortcut-v1.0.0-beta.4) - 2026-10-27

### Other
- release plz ci ([#112](https://github.com/harmony-contrib/openharmony-ability/pull/112))

## [1.0.0-beta.3]

- Introduce the `ohos.global-shortcut` facade for registering, unregistering and clearing
  system hotkeys, with a Rust receiver for named shortcut-triggered events.
- Guard registration with the API 14 capability requirement and keep platform listeners
  scoped to the active plugin lifecycle.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
