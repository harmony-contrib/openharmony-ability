# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.4](https://github.com/harmony-contrib/openharmony-ability/compare/openharmony-ability-plugin-fault-injection-v1.0.0-beta.3...openharmony-ability-plugin-fault-injection-v1.0.0-beta.4) - 2026-10-27

### Other
- release plz ci ([#112](https://github.com/harmony-contrib/openharmony-ability/pull/112))

## [1.0.0-beta.3]

- Introduce the optional `ohos.fault-injection` plugin and named requests to set and clear
  dispatch fault rules.
- Install interception through the host's generic dispatch-hook API; fault injection stays
  disabled unless explicitly registered and configured.
- `set_fault_rule` enables the registry before adding a rule; `clear_fault_rules` clears rules
  without disabling it. Delay/timeout outcomes apply only to async dispatch.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
