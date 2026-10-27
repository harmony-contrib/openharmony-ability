# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.3]

- Introduce the `ohos.menu` async plugin for window menu bars, popup menus, visibility and
  predefined actions, with menu-click and menu-open callbacks.
- Preserve dropdown state across menu updates and refresh menu content when opening it.
- Render separators and accelerator labels, and match shortcuts with the correct modifier state.
- Mount menu bars through the core host's menu slot without making the core depend on this HAR.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
