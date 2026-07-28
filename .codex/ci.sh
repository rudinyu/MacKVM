#!/usr/bin/env bash
set -euo pipefail

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

swift build --disable-sandbox
swift test --disable-sandbox
# Exercise the documented no-argument output path in addition to the explicit
# per-architecture bundles. The native and matching explicit build share a
# cache, so the duplicate packaging check stays inexpensive on either host.
./scripts/build-app.sh
./scripts/build-app.sh --arch arm64
./scripts/build-app.sh --arch x86_64

assert_build_app_rejected() {
  local description="$1"
  shift

  if ./scripts/build-app.sh "$@" >/dev/null 2>&1; then
    echo "$description was unexpectedly accepted." >&2
    exit 1
  else
    local status=$?
  fi

  if [[ "$status" -ne 2 ]]; then
    echo "$description returned $status instead of 2." >&2
    exit 1
  fi
}

assert_build_app_rejected "Invalid architecture" --arch invalid
assert_build_app_rejected "Invalid equals-form architecture" --arch=invalid
assert_build_app_rejected "Missing architecture value" --arch
