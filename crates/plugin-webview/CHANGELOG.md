# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Add native-tree WebView embedding with Ability-owned attachment targets and guarded
  synchronous retirement. Native subscription routes use target IDs and RAII cleanup.
- **Breaking:** register `WebviewBridgePlugin::new()` instead of the former unit value;
  it stores native subscriptions only. Existing controller/protocol/proxy APIs are unchanged.
- Remove the unreleased per-instance declaration owner, separate controller generation,
  unused document-options action, and mocked declaration-host tests (AB6/AB7/AB11).
- Run production native-embedding and target-route regression tests in pull-request CI.

## [1.0.0-beta.3]

- Add optional DOM storage and document-start initialization scripts to WebView creation.
- Expand the handle API with URL/header and HTML loading, visibility/background/bounds, zoom,
  focus/reload, cookies, browsing-data cleanup, user agent and debugging controls.
- Add PDF creation/printing with print-state events, page snapshots, viewport PNG capture and
  pixel-color queries; expose engine-version queries.
- Add HTTPS interception, async custom-protocol helpers and registration rollback, plus named
  callbacks for page lifecycle, drag/drop, new-window requests and close requests.
- Harden controller readiness, stale-controller rejection and cleanup across creation failures,
  replacement and plugin teardown.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
