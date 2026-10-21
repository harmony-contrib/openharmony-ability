#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../../.." && pwd)"
target="${CARGO_TARGET_DIR:-"$repo/target"}/attachment-host"
mkdir -p "$target"
rustc --edition 2021 --test "$repo/crates/ability/src/node/attachment_state.rs" \
  -o "$target/tests"
"$target/tests" "$@"
