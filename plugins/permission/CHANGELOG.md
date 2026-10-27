# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.3]

- Align the existing `ohos.permission` package with the unified workspace release; no action
  or named N-API contract changes in this version.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.

## [1.0.0-beta.1]

- **Breaking**: remove the numeric plugin version and module selection from the ArkTS contract;
  the host now matches this plugin by ID and validates its execution mode and required contexts
  against the Rust registry declaration.
- Plugin instances are session-scoped and cannot be reused across modules or Ability sessions.

## [1.0.0-beta.0]

- Initial release: typed `ohos.permission` plugin for runtime permission requests.
- Result order and failure code `-1` preserved from the legacy helper.
- Requires `ability` context; async action callable from any Rust thread.
