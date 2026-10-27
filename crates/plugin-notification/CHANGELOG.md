# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.3]

- Introduce the `ohos.notification` facade for showing and dismissing system notifications.
- Support up to three action buttons, validating the complete list before platform side effects.
- Route notification taps/actions through the application URI scheme configured on the ArkTS
  factory; no application scheme is hardcoded by the framework.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
