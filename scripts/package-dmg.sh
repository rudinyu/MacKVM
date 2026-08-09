#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/package-dmg.sh [--arch universal|arm64|x86_64]
       [--sign SIGNING_IDENTITY] [--require-developer-id]

Without --sign, the app is ad-hoc signed for local testing. Use a Developer ID
Application identity plus --require-developer-id before distributing outside
your own Macs.
EOF
}

requested_arch="universal"
signing_identity=""
require_developer_id=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      requested_arch="$2"
      shift 2
      ;;
    --arch=*)
      requested_arch="${1#--arch=}"
      shift
      ;;
    --sign)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      signing_identity="$2"
      shift 2
      ;;
    --sign=*)
      signing_identity="${1#--sign=}"
      shift
      ;;
    --require-developer-id)
      require_developer_id=true
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

case "$requested_arch" in
  universal|arm64|x86_64)
    ;;
  *)
    echo "Unsupported architecture: $requested_arch" >&2
    exit 2
    ;;
esac

if [[ "$require_developer_id" == true && -z "$signing_identity" ]]; then
  echo "--require-developer-id needs --sign 'Developer ID Application: …'" >&2
  exit 2
fi

if [[ "$requested_arch" == universal ]]; then
  ./scripts/build-app.sh --arch arm64
  ./scripts/build-app.sh --arch x86_64
  app_dir="$project_root/dist/universal/MacKVM.app"
  rm -rf "$app_dir"
  mkdir -p "$project_root/dist/universal"
  ditto "$project_root/dist/arm64/MacKVM.app" "$app_dir"
  lipo -create \
    "$project_root/dist/arm64/MacKVM.app/Contents/MacOS/MacKVM" \
    "$project_root/dist/x86_64/MacKVM.app/Contents/MacOS/MacKVM" \
    -output "$app_dir/Contents/MacOS/MacKVM"
else
  ./scripts/build-app.sh --arch "$requested_arch"
  app_dir="$project_root/dist/$requested_arch/MacKVM.app"
fi

if [[ -n "$signing_identity" ]]; then
  codesign --force --deep --sign "$signing_identity" "$app_dir"
else
  codesign --force --deep --sign - "$app_dir"
fi

verify_arguments=(
  --app "$app_dir"
  --arch "$requested_arch"
)
if [[ "$require_developer_id" == true ]]; then
  verify_arguments+=(--require-developer-id)
fi
./scripts/verify-release.sh "${verify_arguments[@]}"

version="$(plutil -extract CFBundleShortVersionString raw -o - \
  "$app_dir/Contents/Info.plist")"
dmg_path="$project_root/dist/MacKVM-$version-$requested_arch.dmg"
rm -f "$dmg_path"
hdiutil create \
  -volname "MacKVM $version" \
  -srcfolder "$app_dir" \
  -ov \
  -format UDZO \
  "$dmg_path" >/dev/null

echo "Created $dmg_path"
