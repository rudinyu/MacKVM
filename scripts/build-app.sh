#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build-app.sh [--arch native|arm64|x86_64]
       [--sign SIGNING_IDENTITY]

Without --sign, the app is ad-hoc signed for local testing. A non-ad-hoc
identity is signed with the hardened runtime enabled.
EOF
}

requested_arch="native"
signing_identity=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      requested_arch="$2"
      shift 2
      ;;
    --arch=*)
      requested_arch="${1#--arch=}"
      if [[ -z "$requested_arch" ]]; then
        usage
        exit 2
      fi
      shift
      ;;
    --sign)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage
        exit 2
      fi
      signing_identity="$2"
      shift 2
      ;;
    --sign=*)
      signing_identity="${1#--sign=}"
      if [[ -z "$signing_identity" ]]; then
        usage
        exit 2
      fi
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

host_arch="$(uname -m)"
if [[ "$requested_arch" == "native" ]]; then
  target_arch="$host_arch"
  app_dir="$project_root/dist/MacKVM.app"
else
  target_arch="$requested_arch"
  app_dir="$project_root/dist/$target_arch/MacKVM.app"
fi

case "$target_arch" in
  arm64|x86_64)
    ;;
  *)
    echo "Unsupported architecture: $target_arch" >&2
    exit 2
    ;;
esac

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

export CLANG_MODULE_CACHE_PATH="$project_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

# Keep architecture build databases isolated so cached object files can never
# leak from one target architecture into the other.
scratch_path="$project_root/.build/app-$target_arch"
target_triple="$target_arch-apple-macosx"
build_arguments=(
  -c release
  --disable-sandbox
  --scratch-path "$scratch_path"
  --triple "$target_triple"
)

swift build "${build_arguments[@]}"
# SwiftPM places an explicit triple under <scratch>/<triple>/<configuration>;
# CI verifies this path for both supported architectures on the build host.
binary_dir="$scratch_path/$target_triple/release"
binary_path="$binary_dir/MacKVM"

if [[ ! -x "$binary_path" ]]; then
  echo "Built executable was not found at $binary_path" >&2
  exit 1
fi

plutil -lint "$project_root/Resources/Info.plist"

contents_dir="$app_dir/Contents"
executable_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
app_icon="$project_root/Resources/AppIcon.icns"
compiled_assets="$project_root/Resources/Assets.car"

if [[ ! -f "$app_icon" || ! -f "$compiled_assets" ]]; then
  echo "Compiled app icon resources were not found." >&2
  echo "Run scripts/regenerate-app-icon.sh with full Xcode installed." >&2
  exit 1
fi

# Recreate the bundle from a clean, explicitly validated output path. Reusing
# an old app directory would allow stale nested files or Finder sidecars to be
# copied into a later signed release. Keep this removal narrowly scoped to the
# three paths owned by this build script.
case "$app_dir" in
  "$project_root/dist/MacKVM.app"|\
  "$project_root/dist/arm64/MacKVM.app"|\
  "$project_root/dist/x86_64/MacKVM.app")
    ;;
  *)
    echo "Refusing to replace an unexpected app path: $app_dir" >&2
    exit 1
    ;;
esac
rm -rf -- "$app_dir"
mkdir -p "$executable_dir" "$resources_dir"
install -m 755 "$binary_path" \
  "$executable_dir/MacKVM"
install -m 644 "$project_root/Resources/Info.plist" \
  "$contents_dir/Info.plist"
install -m 644 "$app_icon" "$resources_dir/AppIcon.icns"
install -m 644 "$compiled_assets" "$resources_dir/Assets.car"

# SwiftUI resolves Localizable.strings and InfoPlist.strings from the app
# bundle. Copy checked-in localizations without depending on Xcode's resource
# compiler, so arm64 and x86_64 use the same packaging path.
for localization_dir in "$project_root"/Resources/*.lproj; do
  [[ -d "$localization_dir" ]] || continue
  ditto --norsrc "$localization_dir" \
    "$resources_dir/$(basename "$localization_dir")"
done

if [[ -n "$signing_identity" ]]; then
  codesign --force --deep --options runtime --sign "$signing_identity" "$app_dir"
else
  codesign --force --deep --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
if ! lipo "$executable_dir/MacKVM" -verify_arch "$target_arch"; then
  echo "Built binary at $executable_dir/MacKVM does not contain $target_arch." >&2
  exit 1
fi

echo "Built $app_dir ($target_arch)"
