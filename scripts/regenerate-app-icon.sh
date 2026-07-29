#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
actool="$developer_dir/usr/bin/actool"

if [[ ! -x "$actool" ]]; then
  echo "Full Xcode is required to regenerate the app icon." >&2
  echo "Set DEVELOPER_DIR to Xcode.app/Contents/Developer and retry." >&2
  exit 1
fi

asset_output="$(mktemp -d "${TMPDIR:-/tmp}/mackvm-assets.XXXXXX")"
trap 'rm -rf -- "$asset_output"' EXIT

"$actool" "$project_root/Resources/Assets.xcassets" \
  --compile "$asset_output" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$asset_output/partial.plist" \
  --warnings \
  --errors \
  --notices

install -m 644 "$asset_output/AppIcon.icns" \
  "$project_root/Resources/AppIcon.icns"
install -m 644 "$asset_output/Assets.car" \
  "$project_root/Resources/Assets.car"

echo "Regenerated Resources/AppIcon.icns and Resources/Assets.car"
