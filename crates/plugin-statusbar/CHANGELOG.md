# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.3]

- Introduce the `ohos.statusbar` facade for adding/removing status-bar items and updating icons,
  menus and tooltips, plus predefined menu actions.
- Deliver icon/menu clicks through injected Rust event senders.
- Depend on the menu crate for shared menu behavior, mirroring the ArkTS plugin dependency.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
