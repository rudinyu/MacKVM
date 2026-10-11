#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/package-dmg.sh [--arch universal|arm64|x86_64]
       [--sign SIGNING_IDENTITY] [--require-developer-id]
       [--installer-sign INSTALLER_IDENTITY] [--pkg-only]
       [--use-shared-signing] [--notarization-config PATH]

Without --sign, the app is ad-hoc signed for local testing. Use a Developer ID
Application identity and a Developer ID Installer identity before distributing
outside your own Macs. Without --installer-sign, the local-testing package is
unsigned.

--use-shared-signing applies the installed Codex macOS signing helper to the
finished app before the package is built. --pkg-only builds the app and package
without composing a DMG; it is used to notarize the package before embedding it
in the release DMG.
EOF
}

requested_arch="universal"
signing_identity=""
installer_signing_identity=""
require_developer_id=false
use_shared_signing=false
notarization_config=""
pkg_only=false

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
    --installer-sign)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      installer_signing_identity="$2"
      shift 2
      ;;
    --installer-sign=*)
      installer_signing_identity="${1#--installer-sign=}"
      [[ -n "$installer_signing_identity" ]] || { usage; exit 2; }
      shift
      ;;
    --pkg-only)
      pkg_only=true
      shift
      ;;
    --require-developer-id)
      require_developer_id=true
      shift
      ;;
    --use-shared-signing)
      use_shared_signing=true
      shift
      ;;
    --notarization-config)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      notarization_config="$2"
      shift 2
      ;;
    --notarization-config=*)
      notarization_config="${1#--notarization-config=}"
      [[ -n "$notarization_config" ]] || { usage; exit 2; }
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
if [[ "$require_developer_id" == true && -z "$installer_signing_identity" ]]; then
  echo "--require-developer-id needs --installer-sign 'Developer ID Installer: …'" >&2
  exit 2
fi
if [[ -n "$installer_signing_identity" && "$installer_signing_identity" != "Developer ID Installer:"* ]]; then
  echo "--installer-sign must name a Developer ID Installer identity." >&2
  exit 2
fi
if [[ "$use_shared_signing" == true && -z "$signing_identity" ]]; then
  echo "--use-shared-signing needs --sign 'Developer ID Application: …'" >&2
  exit 2
fi

notarization_tool="${MACKVM_NOTARIZATION_TOOL:-${HOME:-}/.codex/skills/macos-notarization-release/scripts/macos_notarization.py}"
if [[ "$use_shared_signing" == true && ! -f "$notarization_tool" ]]; then
  echo "Shared macOS notarization helper was not found: $notarization_tool" >&2
  exit 2
fi

# A DMG is one multi-architecture build batch. Clean its generated state once
# here, then keep the architecture bundles while composing the image below.
./scripts/clean-build.sh

if [[ "$requested_arch" == universal ]]; then
  # Keep the first app while adding the second architecture; otherwise the
  # second invocation would remove the first bundle before lipo combines them.
  if [[ -n "$signing_identity" && "$use_shared_signing" != true ]]; then
    ./scripts/build-app.sh --arch arm64 --sign "$signing_identity" --no-clean
    ./scripts/build-app.sh --arch x86_64 --sign "$signing_identity" --no-clean
  else
    ./scripts/build-app.sh --arch arm64 --no-clean
    ./scripts/build-app.sh --arch x86_64 --no-clean
  fi
  app_dir="$project_root/dist/universal/MacKVM.app"
  rm -rf "$app_dir"
  mkdir -p "$project_root/dist/universal"
  ditto "$project_root/dist/arm64/MacKVM.app" "$app_dir"
  lipo -create \
    "$project_root/dist/arm64/MacKVM.app/Contents/MacOS/MacKVM" \
    "$project_root/dist/x86_64/MacKVM.app/Contents/MacOS/MacKVM" \
    -output "$app_dir/Contents/MacOS/MacKVM"
else
  if [[ -n "$signing_identity" && "$use_shared_signing" != true ]]; then
    ./scripts/build-app.sh --arch "$requested_arch" --sign "$signing_identity" --no-clean
  else
    ./scripts/build-app.sh --arch "$requested_arch" --no-clean
  fi
  app_dir="$project_root/dist/$requested_arch/MacKVM.app"
fi

if [[ "$use_shared_signing" == true ]]; then
  signing_arguments=(sign "$app_dir" --authorized --identity "$signing_identity")
  if [[ -n "$notarization_config" ]]; then
    signing_arguments+=(--config "$notarization_config")
  fi
  python3 "$notarization_tool" "${signing_arguments[@]}"
elif [[ -n "$signing_identity" ]]; then
  codesign --force --deep --options runtime --timestamp \
    --sign "$signing_identity" "$app_dir"
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
pkg_path="$project_root/dist/MacKVM-$version-$requested_arch.pkg"
rm -f -- "$pkg_path" "$pkg_path.sha256" "$pkg_path.notary.json"
pkgbuild_arguments=(
  --component "$app_dir"
  --install-location /Applications
)
if [[ -n "$installer_signing_identity" ]]; then
  pkgbuild_arguments+=(--sign "$installer_signing_identity")
fi
pkgbuild_arguments+=("$pkg_path")
pkgbuild "${pkgbuild_arguments[@]}"

if [[ -n "$installer_signing_identity" ]]; then
  package_signature="$(pkgutil --check-signature "$pkg_path")"
  grep -F -- "$installer_signing_identity" <<<"$package_signature" >/dev/null || {
    echo "The package signature does not match the requested Developer ID Installer identity." >&2
    exit 1
  }
fi

echo "Created PKG: $pkg_path"
if [[ "$pkg_only" == true ]]; then
  exit 0
fi

./scripts/compose-dmg.sh \
  --pkg "$pkg_path" \
  --version "$version" \
  --arch "$requested_arch"
