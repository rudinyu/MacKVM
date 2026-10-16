#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_root"
source "$project_root/scripts/lib/build-environment.sh"
original_arguments=("$@")
original_argument_count=$#

usage() {
  cat >&2 <<'EOF'
Usage: scripts/compose-dmg.sh --pkg PATH --version VERSION \
       --arch universal|arm64|x86_64

Creates a DMG containing the supplied installer package and bilingual install
guides. The package is copied as-is so a previously stapled ticket is retained.
EOF
}

pkg_path=""
version=""
requested_arch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pkg)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      pkg_path="$2"
      shift 2
      ;;
    --pkg=*)
      pkg_path="${1#--pkg=}"
      [[ -n "$pkg_path" ]] || { usage; exit 2; }
      shift
      ;;
    --version)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      version="$2"
      shift 2
      ;;
    --version=*)
      version="${1#--version=}"
      [[ -n "$version" ]] || { usage; exit 2; }
      shift
      ;;
    --arch)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      requested_arch="$2"
      shift 2
      ;;
    --arch=*)
      requested_arch="${1#--arch=}"
      [[ -n "$requested_arch" ]] || { usage; exit 2; }
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

[[ -n "$pkg_path" && -n "$version" && -n "$requested_arch" ]] || {
  usage
  exit 2
}
case "$requested_arch" in
  universal|arm64|x86_64) ;;
  *)
    echo "Unsupported architecture: $requested_arch" >&2
    exit 2
    ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Invalid version: $version (expected numeric major.minor.patch)" >&2
  exit 2
}
[[ -f "$pkg_path" ]] || {
  echo "Installer package not found: $pkg_path" >&2
  exit 1
}

if [[ "$original_argument_count" -eq 0 ]]; then
  mackvm_enter_build_lock "$project_root" "$project_root/scripts/compose-dmg.sh"
else
  mackvm_enter_build_lock "$project_root" "$project_root/scripts/compose-dmg.sh" \
    "${original_arguments[@]}"
fi

staging_root="$project_root/dist/.staging"
mkdir -p "$staging_root"
staging_dir="$(mktemp -d "$staging_root/MacKVM.XXXXXX")"
cleanup_staging() {
  if [[ -n "$staging_dir" && -d "$staging_dir" ]]; then
    rm -rf -- "$staging_dir"
  fi
  if [[ -d "$staging_root" ]]; then
    rmdir "$staging_root" 2>/dev/null || true
  fi
}
trap cleanup_staging EXIT

dmg_path="$project_root/dist/MacKVM-$version-$requested_arch.dmg"
checksum_path="$dmg_path.sha256"
rm -f -- "$dmg_path" "$checksum_path"

# The DMG contains a single, regular installer path plus human-readable guides.
# Do not add Finder-executable shell scripts or duplicate loose app bundles.
install -m 644 "$pkg_path" "$staging_dir/MacKVM.pkg"
install -m 644 "$project_root/INSTALL.md" "$staging_dir/INSTALL.md"
install -m 644 "$project_root/INSTALL.zh-TW.md" \
  "$staging_dir/INSTALL.zh-TW.md"

hdiutil create \
  -volname "MacKVM $version" \
  -srcfolder "$staging_dir" \
  -ov \
  -format UDZO \
  "$dmg_path" >/dev/null

# Keep only the DMG basename in the sidecar so the pair can be moved together.
(cd "$(dirname "$dmg_path")" && \
  shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$checksum_path")")

echo "Created $dmg_path"
echo "SHA-256: $checksum_path"
