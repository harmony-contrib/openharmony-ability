# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.3]

- Align the existing inbound-only `ohos.resource` facade with the unified workspace release;
  no outbound actions or named N-API contract changes are introduced.
- Continue exposing the current plugin instance's native resource manager through
  `ResourceExt` and `ResourceManagerRef`.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
