# Native capability and CI baseline

Native APIs belong in binding wrappers. New framework code must not add direct
`*-sys` dependencies, local FFI imports or runtime symbol loaders. A runtime
version check cannot make a binary referencing newer symbols load on an older
system. Cargo features and the final unified dependency graph determine which
native symbols an application links.

The independent native-attachment stack retains its existing binding revision and
runtime implementation. It does not import the separate desktop runtime stack.
In this stack, `keyboard` selects API 19 and the default `window` feature links
API-22 cursor functions. Native attachments use the binding's API-12 ownership
wrappers. Check the selected APIs before choosing an application's minimum runtime.

## Contract inventory

`cargo run -p xtask -- contracts` generates the canonical
[contract inventory](napi-contracts.md) from Rust syntax. It covers named macro and
handwritten `BridgeNapiType` declarations, nested N-API objects, and plugin mode
and context declarations. `--check` compares the output byte-for-byte and fails
with a regeneration command when the committed file is stale.

Callback markers such as `NativeNodeReady` contain owned IDs, while their
handshake decoders also read borrowed FrameNode/NodeContent values from the same
N-API callback. The inventory distinguishes those explicit object reads from
Rust marker fields; it does not invent transferable native-object fields or infer
action routing. Keep lifecycle and action semantics in the
[plugin standard](plugin-development-standard.md).

## CI SDK and tests

CI installs OpenHarmony **7.0 / API 26** with
`openharmony-rs/setup-ohos-sdk@v1.0.1`, asserts the API, and exports SDK parser and
ARM64 compiler paths. This is a compile SDK baseline, not a change to deployment
settings or a claim that all linked features work on older devices.

```sh
pnpm run test:contracts
pnpm test
bash crates/ability/tests/run-attachment-host.sh
```

Rust contract tooling tests run on the host without native libraries. The Node
runner discovers `.cjs` files and named `.test` / `.spec` / `-regressions` `.mjs`
and `.js` files under `scripts/`, `native_ability/tests/` and `plugins/*/tests/`.
Dependency/build directories are excluded. It invokes `node --test` with
`--experimental-vm-modules`, preserving the production lifecycle tests' VM module
support. SDK-dependent tests read the parser through `OHOS_SDK_HOME`.

The attachment shell runner executes the actual dependency-free Rust attachment
state tests, without copying sources or substituting native FFI. Node lifecycle
tests execute production ArkTS control flow with native effects substituted; they
do not establish device acceptance.

Plugin tests inherit OHOS library imports from core. `pnpm run test:plugins`
therefore cross-compiles the real ARM64 test binaries with the SDK linker
(`--no-run`); it does not claim Linux/macOS or device execution. CI also links both
native demo modules and retains the existing multi-architecture Clippy checks.

## Native boundary diagnostic

`cargo run -p xtask --locked -- native-boundary` uses Cargo metadata (including
renamed and target-specific dependencies) and `syn` to check native imports/calls.
Comments and string literals are not treated as imports. This is the same guard
as the desktop stack, not a Python source-scraping or fake-library harness.

The independent stack still contains legacy direct sys dependencies and native
resource/Web engine access inherited from main commit
`35dda6f6cc8eef55f4da5142acee1ebb791a7d52`. The
[frozen baseline](native-boundary-baseline.json) records exact dependency/import/
call identities, paths, occurrence counts and recommendation references.
The check rejects new identities, extra occurrences and stale entries: when an
inherited violation disappears, its baseline entry must be removed or reduced.
The baseline may only shrink; it is not a directory/file allowlist and has no
automatic update command. CI and prek enforce the ratchet.

Web engine loader entries cite B22 (`WebEngine::is_evergreen`). Resource-manager
entries cite the main-side boundary migration recommendation and its
`ohos-native-bindings` B17 / PR #186 counterpart; B17 concerns resource-manager
thread safety, not this raw extraction itself. The unused legacy workspace
`napi-sys-ohos` declaration is classified as N-API transport, not OHOS platform FFI.
It cites the explicit recommendation to preserve legitimate core N-API transport,
not an invented audit finding. Opaque N-API types re-exported by `napi-ohos` remain
valid transport and are not flagged.

These frozen main-side issues remain recommendations, **not resolved findings**.
Their removal requires separate binding/runtime work; the CI/contracts slice
does not import the desktop stack wholesale to make its guard green.
