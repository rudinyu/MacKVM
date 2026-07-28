#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

export CLANG_MODULE_CACHE_PATH="$project_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

swift build -c release --disable-sandbox
plutil -lint "$project_root/Resources/Info.plist"

app_dir="$project_root/dist/MacKVM.app"
contents_dir="$app_dir/Contents"
executable_dir="$contents_dir/MacOS"

mkdir -p "$executable_dir"
install -m 755 "$project_root/.build/release/MacKVM" \
  "$executable_dir/MacKVM"
install -m 644 "$project_root/Resources/Info.plist" \
  "$contents_dir/Info.plist"

codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "Built $app_dir"
