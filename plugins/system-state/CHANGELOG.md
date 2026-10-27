# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]


## [1.0.0-beta.4] - 2026-10-27

- Fix desktop window, menu and input lifecycles (#93)

## [1.0.0-beta.3]

- Introduce the `ohos.system-state` async plugin for thermal level, bundle directory,
  available display area and display snapshots.
- Subscribe to thermal, screen/sleep, available-area and display changes and forward named
  events; clean up listeners/subscribers on disposal.
- Use the hyphenated `ohos.system-state` ID and type-name namespace consistently.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
