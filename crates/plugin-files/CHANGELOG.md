# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0-beta.3]

- Add `FileDialogOptions::suggested_name` for save dialogs, validated as non-empty and rejected
  for open-file/open-folder requests.
- Increase the file-dialog timeout to five minutes for interactive browsing and selection.
- Pair with picker fixes that allow capable tablets to select folders and include platform
  error details in failed dialog responses.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
