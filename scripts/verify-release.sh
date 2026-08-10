#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify-release.sh --app PATH --arch arm64|x86_64|universal [--require-developer-id]

Verifies the app bundle metadata, Mach-O architecture, and code signature.
EOF
}

app_path=""
expected_arch=""
require_developer_id=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      app_path="$2"
      shift 2
      ;;
    --app=*)
      app_path="${1#--app=}"
      shift
      ;;
    --arch)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      expected_arch="$2"
      shift 2
      ;;
    --arch=*)
      expected_arch="${1#--arch=}"
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

if [[ -z "$app_path" || -z "$expected_arch" ]]; then
  usage
  exit 2
fi

case "$expected_arch" in
  arm64|x86_64|universal)
    ;;
  *)
    echo "Unsupported expected architecture: $expected_arch" >&2
    exit 2
    ;;
esac

if [[ "$app_path" != /* ]]; then
  app_path="$project_root/$app_path"
fi
binary_path="$app_path/Contents/MacOS/MacKVM"

[[ -d "$app_path" ]] || { echo "App bundle not found: $app_path" >&2; exit 1; }
[[ -x "$binary_path" ]] || { echo "App executable not found: $binary_path" >&2; exit 1; }

plutil -lint "$app_path/Contents/Info.plist" >/dev/null
bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")"
bundle_executable="$(plutil -extract CFBundleExecutable raw -o - "$app_path/Contents/Info.plist")"
[[ "$bundle_identifier" == "app.mackvm.MacKVM" ]] || {
  echo "Unexpected bundle identifier: $bundle_identifier" >&2
  exit 1
}
[[ "$bundle_executable" == "MacKVM" ]] || {
  echo "Unexpected bundle executable: $bundle_executable" >&2
  exit 1
}

codesign --verify --deep --strict "$app_path"
archs="$(lipo -archs "$binary_path")"
case "$expected_arch" in
  arm64|x86_64)
    case " $archs " in
      *" $expected_arch "*) ;;
      *)
        echo "Expected $expected_arch in binary, found: $archs" >&2
        exit 1
        ;;
    esac
    ;;
  universal)
    case " $archs " in *" arm64 "*) ;; *)
      echo "Universal binary is missing arm64: $archs" >&2
      exit 1
      ;;
    esac
    case " $archs " in *" x86_64 "*) ;; *)
      echo "Universal binary is missing x86_64: $archs" >&2
      exit 1
      ;;
    esac
    ;;
esac

signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1 || true)"
if [[ "$require_developer_id" == true ]]; then
  if grep -q "Signature=adhoc" <<<"$signature_details"; then
    echo "Developer ID signature required, but the app is ad-hoc signed." >&2
    exit 1
  fi
  grep -q "Authority=Developer ID Application:" <<<"$signature_details" || {
    echo "Developer ID Application authority was not found in the signature." >&2
    exit 1
  }
  grep -Eq 'CodeDirectory .*flags=0x[0-9a-fA-F]+\([^)]*runtime' <<<"$signature_details" || {
    echo "Hardened runtime was not enabled for the Developer ID signature." >&2
    exit 1
  }
fi

echo "Verified $app_path ($archs; ${bundle_identifier})"
if grep -q "Signature=adhoc" <<<"$signature_details"; then
  echo "Signature: ad-hoc (local testing only; not notarized)"
else
  echo "Signature: Developer ID or other designated signer"
fi
