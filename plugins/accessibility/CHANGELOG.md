# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]


## [1.0.0-beta.4] - 2026-10-27

- Implement named announcement/focus and live-region requests (API 12/18), keeping
  interruption policy caller-owned and reporting system/session errors (AB2/AB3).
- Share one API-23 reduce-motion listener across instance-owned subscriptions;
  reconcile Rust routes at installation and configuration updates, with no worker,
  executor, or queued replay (AB12).
- **Breaking / paired ABI migration:** require the matching Rust crate's new
  `SubscriptionsRequest` / `Subscriptions` ready event. Existing motion/request
  fields are unchanged; `accepted = false` prunes retired Rust routes.
- Rust Drop retires local delivery only; await `close()` for prompt platform
  unsubscribe. The demo stop export now returns `Promise<void>`.
- Unsubscribe by exact callback identity; preserve failed cleanup for retry and
  ignore stale or disposed callbacks. Wire Node contract tests into PR CI.

## [1.0.0-beta.3]

- Introduce the `ohos.accessibility` async plugin for font scale, accessibility-enabled and
  touch-exploration state queries through named N-API values.
- Add lifecycle-scoped accessibility state listeners with explicit subscribe/unsubscribe and
  callbacks to the matching Rust plugin instance.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
