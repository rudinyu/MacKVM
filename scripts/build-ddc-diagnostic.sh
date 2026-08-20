#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build-ddc-diagnostic.sh [--arch native|arm64|x86_64|universal]
       [--output PATH]

Builds the standalone native DDC diagnostic tool. The tool is intentionally
not part of the MacKVM.app bundle; copy it to the Mac being diagnosed.
EOF
}

requested_arch="native"
output_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      requested_arch="$2"
      shift 2
      ;;
    --arch=*)
      requested_arch="${1#--arch=}"
      [[ -n "$requested_arch" ]] || { usage; exit 2; }
      shift
      ;;
    --output)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      output_path="$2"
      shift 2
      ;;
    --output=*)
      output_path="${1#--output=}"
      [[ -n "$output_path" ]] || { usage; exit 2; }
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
else
  target_arch="$requested_arch"
fi

case "$target_arch" in
  arm64|x86_64|universal)
    ;;
  *)
    echo "Unsupported architecture: $target_arch" >&2
    exit 2
    ;;
esac

if [[ -z "$output_path" ]]; then
  if [[ "$target_arch" == "universal" ]]; then
    output_path="$project_root/dist/ddc-diagnostic-universal"
  else
    output_path="$project_root/dist/ddc-diagnostic-$target_arch"
  fi
elif [[ "$output_path" != /* ]]; then
  output_path="$project_root/$output_path"
fi

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

source_file="$project_root/Tools/DDCDiagnostic/ddc-diagnostic.m"
native_file="$project_root/Sources/MacKVMNativeDDC/MacKVMNativeDDC.m"
include_dir="$project_root/Sources/MacKVMNativeDDC/include"
module_cache_path="$project_root/.build/DDCDiagnosticModuleCache"
mkdir -p "$module_cache_path"
mkdir -p "$(dirname "$output_path")"

build_one() {
  local architecture="$1"
  local destination="$2"
  clang \
    -arch "$architecture" \
    -mmacosx-version-min=13.0 \
    -std=c11 \
    -O2 \
    -Wall \
    -Wextra \
    -Wno-deprecated-declarations \
    -Wno-unused-function \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$module_cache_path" \
    -I "$include_dir" \
    "$source_file" \
    "$native_file" \
    -framework CoreFoundation \
    -framework CoreGraphics \
    -framework CoreDisplay \
    -framework Foundation \
    -framework IOKit \
    -o "$destination"
  chmod 755 "$destination"
  lipo "$destination" -verify_arch "$architecture"
}

if [[ "$target_arch" == "universal" ]]; then
  scratch_path="$(mktemp -d "${TMPDIR:-/tmp}/mackvm-ddc-diagnostic.XXXXXX")"
  trap 'rm -rf -- "$scratch_path"' EXIT
  build_one arm64 "$scratch_path/ddc-diagnostic-arm64"
  build_one x86_64 "$scratch_path/ddc-diagnostic-x86_64"
  lipo -create \
    "$scratch_path/ddc-diagnostic-arm64" \
    "$scratch_path/ddc-diagnostic-x86_64" \
    -output "$output_path"
  chmod 755 "$output_path"
  lipo "$output_path" -verify_arch arm64 x86_64
else
  build_one "$target_arch" "$output_path"
fi

echo "Built $output_path ($target_arch)"
