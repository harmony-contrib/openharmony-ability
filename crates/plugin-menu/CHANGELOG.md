# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.4](https://github.com/harmony-contrib/openharmony-ability/compare/openharmony-ability-plugin-menu-v1.0.0-beta.3...openharmony-ability-plugin-menu-v1.0.0-beta.4) - 2026-10-27

### Added
- *(menu)* support renderer-owned accelerator hints ([#95](https://github.com/harmony-contrib/openharmony-ability/pull/95)) ([#95](https://github.com/harmony-contrib/openharmony-ability/issues/95) [#95](https://github.com/harmony-contrib/openharmony-ability/issues/95) )

### Other
- release plz ci ([#112](https://github.com/harmony-contrib/openharmony-ability/pull/112))
- Fix desktop window, menu and input lifecycles ([#93](https://github.com/harmony-contrib/openharmony-ability/pull/93))

## [1.0.0-beta.3]

- Introduce the `ohos.menu` async facade for window menu bars, popup menus, visibility and
  predefined actions.
- Deliver menu-click and menu-open events through injected Rust senders; cache menu content
  and visibility only after successful bridge calls.
- Pair with dropdown state fixes, separator and shortcut-label rendering, and modifier-aware
  accelerator matching in the ArkTS implementation.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
