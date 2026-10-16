#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_root"

source "$project_root/scripts/lib/build-environment.sh"
mackvm_select_xcode

echo "MacKVM build environment"
echo "Xcode: $MACKVM_XCODE_VERSION"
echo "DEVELOPER_DIR: $DEVELOPER_DIR"
echo "Swift: $MACKVM_SWIFT_VERSION"
echo "Swift path: $MACKVM_SWIFT_PATH"
echo "Clang path: $MACKVM_CLANG_PATH"
echo "macOS SDK: $MACKVM_MACOS_SDK_PATH"
echo "Architecture: $(uname -m)"

if command -v python3 >/dev/null 2>&1; then
  python_path="$(command -v python3)"
  python_version="$(python3 --version 2>&1)"
  echo "Python 3: $python_version ($python_path)"
else
  echo "Python 3: unavailable (needed for notarized packaging tooling)"
fi

if command -v dotnet >/dev/null 2>&1; then
  dotnet_sdks="$(dotnet --list-sdks 2>/dev/null || true)"
  if [[ -n "$dotnet_sdks" ]]; then
    echo "Optional .NET SDKs:"
    printf '%s\n' "$dotnet_sdks"
  else
    echo "Optional .NET SDK: not installed (Windows checks will be skipped)"
  fi
else
  echo "Optional .NET SDK: not installed (Windows checks will be skipped)"
fi

if revision="$(git rev-parse --short=12 HEAD 2>&1)"; then
  :
else
  revision=unknown
fi
if git_status="$(git status --porcelain --untracked-files=normal 2>&1)"; then
  if [[ -n "$git_status" ]]; then
    tree_state=dirty
  else
    tree_state=clean
  fi
else
  tree_state=unknown
  echo "Git status could not be read: $git_status" >&2
fi
echo "Git: $revision ($tree_state)"
