# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.5](https://github.com/harmony-contrib/openharmony-ability/compare/openharmony-ability-plugin-process-v1.0.0-beta.4...openharmony-ability-plugin-process-v1.0.0-beta.5) - 2026-11-02

### Other
- updated the following local packages: openharmony-ability

## [1.0.0-beta.4](https://github.com/harmony-contrib/openharmony-ability/compare/openharmony-ability-plugin-process-v1.0.0-beta.3...openharmony-ability-plugin-process-v1.0.0-beta.4) - 2026-10-27

### Other
- release plz ci ([#112](https://github.com/harmony-contrib/openharmony-ability/pull/112))

## [1.0.0-beta.3]

- Introduce `ProcessExt` and the `ohos.process` async restart action through the platform's
  `appRecovery` API.
- Treat restart as a system-controlled process transition; applications must not rely on
  `onDestroy` running during restart.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
