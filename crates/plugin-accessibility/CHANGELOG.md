# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.4](https://github.com/harmony-contrib/openharmony-ability/compare/openharmony-ability-plugin-accessibility-v1.0.0-beta.3...openharmony-ability-plugin-accessibility-v1.0.0-beta.4) - 2026-10-27

### Added
- *(accessibility)* add typed events and thread-free motion routes ([#105](https://github.com/harmony-contrib/openharmony-ability/pull/105)) ([#105](https://github.com/harmony-contrib/openharmony-ability/issues/105) [#105](https://github.com/harmony-contrib/openharmony-ability/issues/105) )

### Other
- release plz ci ([#112](https://github.com/harmony-contrib/openharmony-ability/pull/112))

- Keep `send_event` (API 12) and `announce_live` (API 18) as owned, named N-API
  requests with explicit platform failures and no consumer policy (AB2/AB3).
- Replace reduced-motion workers, blocking futures, cleanup jobs, and replay with
  plugin-owned RAII routes and ArkTS lifecycle reconciliation (AB12).
- **Breaking:** Drop now retires only Rust delivery; use `close().await` for prompt
  platform unsubscribe. The next notification/context update also prunes retired
  routes; session disposal releases all listeners.
- **Paired ABI migration:** update the crate and HAR together for the additive
  `SubscriptionsRequest` / `Subscriptions` ready event. Existing action/request
  fields stay stable; a motion event's `accepted = false` retires its route.
- Scope screen-reader callbacks to the registered plugin instance, and remove
  only the matching ArkTS system listener.
- Add standalone production-code Rust ownership tests and ArkTS contract tests to CI.

## [1.0.0-beta.3]

- Introduce the `ohos.accessibility` async facade for font scale, accessibility-enabled and
  touch-exploration queries.
- Add state-change subscriptions with named N-API callbacks, explicit unsubscribe, and
  subscription replay after a bridge session is rebuilt.
- Expose `AccessibilityExt`, a worker-safe client and structured error mapping.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
