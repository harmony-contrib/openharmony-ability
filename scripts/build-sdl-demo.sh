#!/bin/bash
#
# Builds the SDL3 validation module against the SDL checkout's current oh_ability adapter.
#
# Usage:
#   scripts/build-sdl-demo.sh [--install] [--arch=arm64-v8a|x86_64] [--clean]
#
# SDL_SOURCE_DIR defaults to /Volumes/PSSD/sdl/SDL and can be overridden for another checkout.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"
C_MODULE_DIR="$ROOT_DIR/c_module"
BUILD_DIR="$C_MODULE_DIR/build-sdl"
SDL_CHECKOUT="${SDL_SOURCE_DIR:-/Volumes/PSSD/sdl/SDL}"

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

if [[ ! -f "$SDL_CHECKOUT/CMakeLists.txt" ]]; then
  echo "error: SDL source checkout not found at $SDL_CHECKOUT" >&2
  exit 1
fi

find_sdk() {
  if [[ -n "${OHOS_SDK:-}" && -d "$OHOS_SDK/native" ]]; then
    echo "$OHOS_SDK/native"
    return
  fi
  local standard_deveco="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
  if [[ -d "$standard_deveco" ]]; then
    echo "$standard_deveco"
    return
  fi
  local deveco=""
  deveco="$(for dir in "$HOME"/.meat/ide/DevEco-Studio-*.app/Contents/sdk/default/openharmony/native; do
    [[ -d "$dir" ]] && echo "$dir"
  done | grep -v -- "-normal.app" | sort -V | tail -1)"
  if [[ -n "$deveco" ]]; then
    echo "$deveco"
    return
  fi
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

if [[ -x "$SDK_NATIVE/build-tools/cmake/bin/cmake" ]]; then
  CMAKE="$SDK_NATIVE/build-tools/cmake/bin/cmake"
  PATH="$SDK_NATIVE/build-tools/cmake/bin:$PATH"
else
  CMAKE="$(command -v cmake || true)"
fi
if [[ -z "$CMAKE" || -z "$(command -v ninja || true)" ]]; then
  echo "error: cmake and ninja are required" >&2
  exit 1
fi

if [[ "$CLEAN" == "1" && -d "$BUILD_DIR" ]]; then
  rm -rf "$BUILD_DIR"
fi

echo "SDL: $SDL_CHECKOUT"
echo "SDK: $SDK_NATIVE"
"$CMAKE" -S "$C_MODULE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DOHOS_ARCH="$ARCH" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DOH_ABILITY_BUILD_SDL_DEMO=ON \
  -DOH_ABILITY_SDL_SOURCE_DIR="$SDL_CHECKOUT"
"$CMAKE" --build "$BUILD_DIR" --target sdl_demo_native --parallel

LIBRARY="$BUILD_DIR/example/sdl_demo_native/libsdl_demo_native.so"
if [[ ! -f "$LIBRARY" ]]; then
  echo "error: build produced no libsdl_demo_native.so ($LIBRARY missing)" >&2
  exit 1
fi
echo "Built: $LIBRARY"

if [[ "$INSTALL" == "1" ]]; then
  TARGET_DIR="$ROOT_DIR/demo/entry/libs/$ARCH"
  mkdir -p "$TARGET_DIR"
  cp "$LIBRARY" "$TARGET_DIR/libsdl_demo_native.so"
  echo "Installed to: $TARGET_DIR/libsdl_demo_native.so"
else
  echo "Not installed (pass --install to copy into demo/entry/libs/$ARCH)."
fi
