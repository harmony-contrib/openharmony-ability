#!/bin/bash
#
# Builds the pure C demo native module (c_module) for an OHOS device ABI and optionally
# installs it into the demo app, replacing the Rust-built libdemo_native.so.
#
# Usage:
#   scripts/build-c-demo.sh [--install] [--arch=arm64-v8a|x86_64] [--clean]
#
# Without --install the artifact is left in c_module/build/example/demo_native/ and the demo
# app keeps its current libdemo_native.so untouched.
#
# SDK resolution order: $OHOS_SDK, then DevEco Studio default locations.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"
C_MODULE_DIR="$ROOT_DIR/c_module"
BUILD_DIR="$C_MODULE_DIR/build"

INSTALL=0
ARCH="arm64-v8a"
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --clean) CLEAN=1 ;;
    --arch=*) ARCH="${arg#--arch=}" ;;
    --arch) echo "use --arch=<abi>" && exit 1 ;;
    *) echo "unknown argument: $arg" && exit 1 ;;
  esac
done

# ---------------------------------------------------------------- SDK
find_sdk() {
  if [[ -n "${OHOS_SDK:-}" && -d "$OHOS_SDK/native" ]]; then
    echo "$OHOS_SDK/native"
    return
  fi
  # Standard DevEco Studio installation on macOS.
  local standard_deveco="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
  if [[ -d "$standard_deveco" ]]; then
    echo "$standard_deveco"
    return
  fi
  # Prefer the newest versioned DevEco Studio installation.
  local deveco=""
  deveco="$(for dir in "$HOME"/.meat/ide/DevEco-Studio-*.app/Contents/sdk/default/openharmony/native; do
    [[ -d "$dir" ]] && echo "$dir"
  done | grep -v -- "-normal.app" | sort -V | tail -1)"
  if [[ -z "$deveco" ]]; then
    for dir in "$HOME"/.meat/ide/DevEco-Studio-*.app/Contents/sdk/default/openharmony/native; do
      [[ -d "$dir" ]] && deveco="$dir"
    done
  fi
  if [[ -n "$deveco" ]]; then
    echo "$deveco"
    return
  fi
  for root in "$HOME/Library/OpenHarmony/Sdk" "$HOME/Downloads/sdk/packages/ohos-sdk"; do
    local best=""
    for dir in "$root"/*/native; do
      [[ -d "$dir" ]] && best="$dir"
    done
    if [[ -n "$best" ]]; then
      echo "$best"
      return
    fi
  done
  echo ""
}

SDK_NATIVE="$(find_sdk)"
if [[ -z "$SDK_NATIVE" ]]; then
  echo "error: OHOS native SDK not found; set OHOS_SDK=/path/to/ohos-sdk" >&2
  exit 1
fi
TOOLCHAIN="$SDK_NATIVE/build/cmake/ohos.toolchain.cmake"
if [[ ! -f "$TOOLCHAIN" ]]; then
  echo "error: ohos.toolchain.cmake not found under $SDK_NATIVE" >&2
  exit 1
fi
echo "SDK: $SDK_NATIVE"

# Prefer the SDK-bundled cmake/ninja when present.
if [[ -x "$SDK_NATIVE/build-tools/cmake/bin/cmake" ]]; then
  CMAKE="$SDK_NATIVE/build-tools/cmake/bin/cmake"
  NINJA="$SDK_NATIVE/build-tools/cmake/bin/ninja"
  PATH="$SDK_NATIVE/build-tools/cmake/bin:$PATH"
else
  CMAKE="$(command -v cmake || true)"
  NINJA="$(command -v ninja || true)"
fi
if [[ -z "$CMAKE" ]]; then
  echo "error: cmake not found" >&2
  exit 1
fi
if [[ -z "$NINJA" ]]; then
  echo "error: ninja not found (install it or use the OHOS SDK build-tools)" >&2
  exit 1
fi

# ---------------------------------------------------------------- build
if [[ "$CLEAN" == "1" && -d "$BUILD_DIR" ]]; then
  rm -rf "$BUILD_DIR"
fi

echo "Configuring (arch=$ARCH)..."
"$CMAKE" -S "$C_MODULE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DOHOS_ARCH="$ARCH" \
  -DCMAKE_BUILD_TYPE=Debug

echo "Building..."
"$CMAKE" --build "$BUILD_DIR" --parallel

LIBRARY="$BUILD_DIR/example/demo_native/libdemo_native.so"
if [[ ! -f "$LIBRARY" ]]; then
  echo "error: build produced no libdemo_native.so ($LIBRARY missing)" >&2
  exit 1
fi
echo "Built: $LIBRARY"

# ---------------------------------------------------------------- install
if [[ "$INSTALL" == "1" ]]; then
  TARGET_DIR="$ROOT_DIR/demo/entry/libs/$ARCH"
  mkdir -p "$TARGET_DIR"
  cp "$LIBRARY" "$TARGET_DIR/libdemo_native.so"
  echo "Installed to: $TARGET_DIR/libdemo_native.so"
  echo "Next: build the demo app (hvigorw assembleHap) and run it on a device."
else
  echo "Not installed (pass --install to copy into demo/entry/libs/$ARCH)."
fi
