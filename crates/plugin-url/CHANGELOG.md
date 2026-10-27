# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.3]

- Add `check_url_scheme` to verify schemes declared for this Ability in the installed manifest;
  runtime registration of URL schemes is not supported by the platform.
- Add `open_file` for `file://` URIs and `reveal_in_dir` for absolute directory paths.
- Accept absolute non-hierarchical URLs such as `mailto:` while rejecting empty or incomplete URLs.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
