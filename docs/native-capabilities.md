# Native capability features

Native APIs are selected at build time through binding features. The framework
and plugins do not probe dynamic libraries or directly depend on `*-sys` crates.
Missing wrappers belong in `ohos-native-bindings`.

| Package | Feature | Linked capability and minimum runtime API | When disabled |
| --- | --- | --- | --- |
| `openharmony-ability` | `keyboard` | ArkUI keyboard delivery, API 14 | Raw XComponent key delivery remains available |
| `openharmony-ability` | `keyboard-focus` | Synchronous `OH_ArkUI_FocusRequest`, API 15; enables `keyboard` | Uses the existing node focus-status attribute |
| `openharmony-ability` | `keyboard-lock-state` | Caps/Num/Scroll lock queries, API 19; enables `keyboard` | Lock states are `None`, not assumed off |
| `openharmony-ability` | `keyboard-text-input` | IME key consumption configuration, API 26; enables `keyboard` | Selecting `ArkUiWithTextInput` returns an error |
| `openharmony-ability` | `keyboard-focus-recovery` | Window-filter inspection, API 26; enables `keyboard-focus` | Enabling window keyboard focus recovery returns an error |
| `openharmony-ability-plugin-webview` | `engine-version` | Active ArkWeb engine version, API 20 | Native engine-version query is absent |
| `openharmony-ability-plugin-webview` | `engine-evergreen` | Evergreen engine query, API 23; enables `engine-version` | Version query omits the evergreen suffix |

These input and engine-query features are opt-in. The existing default `window`
feature selects API-22 cursor functions; using them requires API 22 or newer.
Enabling a feature also requires an SDK and deployment
target that support its APIs. The table describes the APIs added by each feature;
other selected features and dependencies can require a higher API. Cargo unifies
features across consumers, so applications must review the final dependency graph.
A runtime API-version check cannot make a binary referencing newer symbols
loadable on an older system.

Focus recovery also requires the explicit
`set_window_keyboard_focus_recovery(true)` application setting before rendering.
It remains window-scoped and preserves foreign filter ownership. Enabling its
Cargo feature does not automatically install filters.

The workspace uses binding wrappers for native resource-manager initialization,
soft-keyboard demand, focus requests, key locks, IME configuration, window-filter
events and Web engine queries. Bindings own raw imports, null checks, lifetimes
and native error handling.

`napi-ohos` still brings its internal `napi-sys-ohos` dependency, whose manifest
includes `libloading`. Those transitive lockfile entries are not framework
dependencies on raw APIs. The OHOS build keeps N-API's `dyn-symbols` feature off
and links `ace_napi.z` normally; the boundary check also rejects enabling
`dyn-symbols` from workspace manifests.

`python3 scripts/check-native-boundary.py` checks member manifests (including
renamed dependencies) and native imports. `scripts/keyboard-focus-regressions.py`
uses a statically linked SDK substitute and separately tests feature-disabled
configuration without linking that substitute.
