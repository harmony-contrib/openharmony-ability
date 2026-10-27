# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.3]

- Introduce the `ohos.deep-link` async facade for initial and latest launch URIs.
- Add synchronous, consuming accessors for the initial URI and latest Want parameters through
  the current app session; handle cold launches and subsequent `onNewWant` delivery.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
