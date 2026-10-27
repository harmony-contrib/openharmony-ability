# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.3]

- Align the inbound-only `ohos.resource` package with the unified workspace release; no new
  outbound actions or named N-API contract changes.
- Keep resource-manager injection Ability-scoped during plugin installation.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.

## [1.0.0-beta.1]

- **Breaking**: replace the shared `EagerPlugin` wrapper with a session-scoped `LazyPlugin`
  instance; `PluginBase` rejects reuse across modules/sessions.
- Push the manager from Ability-scoped `onInstall`, without requiring a WindowStage or component.
- **Breaking**: move the native manager from a cross-module global into the registered Rust
  `ResourceBridgePlugin` instance.
- **Breaking**: remove the numeric plugin version and module selection; the host now matches the
  factory by ID and validates its execution mode and required contexts against the Rust registry.

## [1.0.0-beta.0]

- Initial release: inbound-only `ohos.resource` plugin wrapping the native `ResourceManager`.
- ArkTS wrapper pushes the resource manager on `ability-create` through a scoped native event; no outbound actions.
- Uses `EagerPlugin` to share one process-wide wrapper instance.
