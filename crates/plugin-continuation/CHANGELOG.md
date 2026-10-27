# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.4](https://github.com/harmony-contrib/openharmony-ability/compare/openharmony-ability-plugin-continuation-v1.0.0-beta.3...openharmony-ability-plugin-continuation-v1.0.0-beta.4) - 2026-10-27

### Other
- release plz ci ([#112](https://github.com/harmony-contrib/openharmony-ability/pull/112))

## [1.0.0-beta.3]

- Introduce `ContinuationExt` and a synchronous client for checking continuation launches and
  consuming restore data from the app session, including cold-start setup.
- Add `set_continuation_data` to pre-register the source snapshot read by `onContinue`;
  reading the snapshot does not consume it, allowing platform retries.
- This is a Rust-only facade over core lifecycle state and exports, with no separate ArkTS
  plugin registration or action for starting a migration.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
