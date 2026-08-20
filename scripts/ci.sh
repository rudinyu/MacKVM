#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

export CLANG_MODULE_CACHE_PATH="$project_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

swift build --disable-sandbox
swift test --disable-sandbox

# Exercise both the documented native output and the two supported release
# architectures. Cross-build validation is intentionally part of CI because
# releases are distributed to both Apple Silicon and Intel Macs.
./scripts/build-app.sh
./scripts/build-app.sh --arch arm64
./scripts/build-app.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch arm64
./scripts/build-ddc-diagnostic.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch universal
./dist/ddc-diagnostic-universal --help >/dev/null

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
