# Native capability features

Native APIs are selected at build time through binding features. The framework
and plugins do not probe dynamic libraries or directly depend on `*-sys` crates.
Missing wrappers belong in `ohos-native-bindings`.

| Package | Feature | Linked capability and minimum runtime API | When disabled |
| --- | --- | --- | --- |
| `openharmony-ability` | `keyboard` | ArkUI keyboard delivery and synchronous `OH_ArkUI_FocusRequest`, API 14/15 | Raw XComponent key delivery remains available |
| `openharmony-ability` | `api-19` | Caps/Num/Scroll lock queries (`OH_ArkUI_KeyEvent_IsCapsLockOn` etc.), API 19 | Lock states are `None`, not assumed off |
| `openharmony-ability` | `api-26` | Explicit IME key consumption configuration, API 26; enables `api-19` | Native key-consumption configuration is not linked |
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

The workspace uses binding wrappers for native resource-manager initialization,
soft-keyboard demand, focus requests, key locks, IME configuration and Web engine
queries. Bindings own raw imports, null checks, lifetimes
and native error handling.

`napi-ohos` still brings its internal `napi-sys-ohos` dependency, whose manifest
includes `libloading`. Those transitive lockfile entries are not framework
dependencies on raw APIs. The OHOS build keeps N-API's `dyn-symbols` feature off
and links `ace_napi.z` normally; the boundary check also rejects enabling
`dyn-symbols` from workspace manifests.

`cargo run -p xtask --locked -- native-boundary` checks Cargo metadata (including
renamed and target-specific direct dependencies) and parses Rust imports/calls
with `syn`. Comments and string literals are not treated as native imports.

## CI SDK and test baseline

The current development stack retains UDMF `842f4d41` for Ability's ArkUI drag
path, matching ArkUI's native Rust types. Clipboard uses UDMF/pasteboard
`a5542e29`; IME also uses that revision. Drag and clipboard therefore have distinct
UDMF identities, which must not cross those facades. This temporary dependency
split is a **D5 release blocker**: unify all binding pins onto the approved
bindings release before any Ability release, then remove the drag-only override.

CI uses OpenHarmony **7.0 / API 26**, installed by
`openharmony-rs/setup-ohos-sdk@v1.0.1`, and asserts the installed API version.
API 12 cannot compile/link the API-19 keyboard, default API-22 window and opt-in
API-26 input paths. The all-features job needs API 26. This is a **compile SDK**
baseline, not a claim that every feature works on older devices or a change to
the demo's deployment settings.

With `OHOS_SDK_HOME` pointing to the SDK directory containing `ets/`:

```sh
pnpm test
pnpm run test:contracts
cargo run -p xtask --locked -- native-boundary
```

The Node runner searches `scripts/`, `native_ability/tests/` and `plugins/*/tests/`
for existing `.cjs` files and named `*.test.mjs` / `*.spec.mjs` /
`*-regressions.mjs` tests (also `.js`), excluding dependency/build directories.
It executes them with `node --test`, using the SDK's real ArkTS parser.
Rust contract tooling tests run on the host without the NDK. The generated
[contract inventory](napi-contracts.md) is checked byte-for-byte against Rust
declarations, including handwritten `BridgeNapiType` implementations.

Plugin tests currently inherit native library imports from core, so they cannot
link or execute on a stock Linux/macOS host. CI uses the SDK linker to compile
the **real** ARM64 plugin test binaries with `pnpm run test:plugins` (`--no-run`)
and links both native demos. It also retains the individual native feature
Clippy configurations. It does not claim to execute plugin tests on a host or
device. Running those binaries requires an OHOS test runner/device environment.
The source-spliced Python keyboard harness and fake native library have been
removed; they did not test the compiled framework against the real bindings.
