# 1.0.0-beta.3

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

## Unreleased

- Add generation-owned native-tree WebView embedding and synchronous edge retirement.
