# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.3]

- Introduce the `ohos.system-state` async facade for thermal level, bundle code directory,
  available display area and display snapshots.
- Deliver thermal, sleep/wake, available-area and display-change notifications through named
  N-API events and an injected Rust sender.
- Use the hyphenated `ohos.system-state` namespace consistently for the plugin ID and type names.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
