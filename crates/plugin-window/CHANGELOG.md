# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.4](https://github.com/harmony-contrib/openharmony-ability/compare/openharmony-ability-plugin-window-v1.0.0-beta.3...openharmony-ability-plugin-window-v1.0.0-beta.4) - 2026-10-27

### Added
- *(window)* add status bar visibility and style control ([#106](https://github.com/harmony-contrib/openharmony-ability/pull/106)) ([#106](https://github.com/harmony-contrib/openharmony-ability/issues/106) [#106](https://github.com/harmony-contrib/openharmony-ability/issues/106) )

### Other
- release plz ci ([#112](https://github.com/harmony-contrib/openharmony-ability/pull/112))
- Fix desktop window, menu and input lifecycles ([#93](https://github.com/harmony-contrib/openharmony-ability/pull/93))

- Add API 12 status-bar visibility, content color and optional ARGB background through
  `WindowClient::set_status_bar`, separate from desktop tray APIs.
- Run the status-bar bridge regression suite in PR CI, including cancellation and
  native-operation failure coverage.
- Add a real Rust-to-platform status-bar demo with native color and navigation-preservation
  assertions, plus device acceptance instructions.

## [1.0.0-beta.3]

- Expand window creation and control with display selection, decorations, transparency,
  fullscreen/focus, geometry, limits, visibility/state, topmost/title and attention requests.
- Add IME positioning, draggable/keep-screen-on settings, cursor visibility/style and real
  platform window-ID queries through named N-API requests.
- Add cancellable prompts anchored in window-content vp coordinates, display-filtered window
  stacking queries, validated RGBA custom cursors and window icons.
- Keep operations scoped to the component's actual window and await platform mutations.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
