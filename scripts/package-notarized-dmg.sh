#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/package-notarized-dmg.sh \
       --sign "Developer ID Application: …" \
       --keychain-profile PROFILE \
       [--arch universal|arm64|x86_64] [--timeout DURATION]

Builds a Developer ID-signed DMG, submits it to Apple's notary service,
staples the accepted ticket, validates the result, and writes a final SHA-256
sidecar. Credentials are read from a notarytool Keychain profile.

This is the distribution path. For local ad-hoc testing, use:
  scripts/package-dmg.sh --arch universal
EOF
}

requested_arch="universal"
signing_identity=""
notary_profile=""
notary_timeout="2h"

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
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      signing_identity="$2"
      shift 2
      ;;
    --sign=*)
      signing_identity="${1#--sign=}"
      shift
      ;;
    --keychain-profile)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      notary_profile="$2"
      shift 2
      ;;
    --keychain-profile=*)
      notary_profile="${1#--keychain-profile=}"
      shift
      ;;
    --timeout)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      notary_timeout="$2"
      shift 2
      ;;
    --timeout=*)
      notary_timeout="${1#--timeout=}"
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

if [[ -z "$signing_identity" ]]; then
  echo "--sign is required for a notarized release." >&2
  exit 2
fi
case "$signing_identity" in
  "Developer ID Application:"*)
    ;;
  *)
    echo "--sign must name a Developer ID Application identity." >&2
    exit 2
    ;;
esac

if [[ -z "$notary_profile" ]]; then
  echo "--keychain-profile is required for a notarized release." >&2
  exit 2
fi

if [[ ! "$notary_timeout" =~ ^[0-9]+[smh]?$ ]]; then
  echo "Invalid notarization timeout: $notary_timeout" >&2
  echo "Use seconds or an integer followed by s, m, or h (for example, 2h)." >&2
  exit 2
fi

identity_list="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! grep -F -- "\"$signing_identity\"" <<<"$identity_list" >/dev/null; then
  echo "Developer ID identity was not found in the login Keychain:" >&2
  echo "  $signing_identity" >&2
  exit 1
fi

./scripts/package-dmg.sh \
  --arch "$requested_arch" \
  --sign "$signing_identity" \
  --require-developer-id

case "$requested_arch" in
  universal)
    app_dir="$project_root/dist/universal/MacKVM.app"
    ;;
  arm64|x86_64)
    app_dir="$project_root/dist/$requested_arch/MacKVM.app"
    ;;
esac

version="$(plutil -extract CFBundleShortVersionString raw -o - \
  "$app_dir/Contents/Info.plist")"
dmg_path="$project_root/dist/MacKVM-$version-$requested_arch.dmg"
checksum_path="$dmg_path.sha256"
notary_log_path="$dmg_path.notary.json"

[[ -f "$dmg_path" ]] || {
  echo "DMG was not created: $dmg_path" >&2
  exit 1
}
rm -f -- "$notary_log_path"

assert_secure_timestamp() {
  local path="$1"
  local signature_details
  signature_details="$(codesign --display --verbose=4 "$path" 2>&1)"
  grep -q "Timestamp=" <<<"$signature_details" || {
    echo "Secure timestamp was not found in the signature: $path" >&2
    exit 1
  }
}

./scripts/verify-release.sh \
  --app "$app_dir" \
  --arch "$requested_arch" \
  --require-developer-id
assert_secure_timestamp "$app_dir"

# A Developer ID signature on the disk image avoids Gatekeeper path
# randomization for a directly distributed DMG. The app inside was already
# signed and verified by package-dmg.sh before this container is signed.
codesign --force --timestamp --sign "$signing_identity" "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"
assert_secure_timestamp "$dmg_path"

submission_plist="$(mktemp -t mackvm-notary)"
cleanup_submission() {
  if [[ -n "$submission_plist" && -f "$submission_plist" ]]; then
    rm -f -- "$submission_plist"
  fi
}
trap cleanup_submission EXIT

if ! xcrun notarytool submit "$dmg_path" \
  --keychain-profile "$notary_profile" \
  --wait \
  --timeout "$notary_timeout" \
  --no-progress \
  --output-format plist >"$submission_plist"; then
  echo "Apple notarization submission failed or timed out." >&2
  cat "$submission_plist" >&2 || true
  exit 1
fi

submission_id="$(plutil -extract id raw -o - "$submission_plist")"
submission_status="$(plutil -extract status raw -o - "$submission_plist")"
cat "$submission_plist"

if [[ "$submission_status" != "Accepted" ]]; then
  echo "Apple notarization was not accepted: $submission_status" >&2
  if ! xcrun notarytool log \
    --keychain-profile "$notary_profile" \
    "$submission_id" "$notary_log_path"; then
    echo "The notarization log was not available." >&2
  else
    echo "Notarization log: $notary_log_path" >&2
  fi
  exit 1
fi

xcrun notarytool log \
  --keychain-profile "$notary_profile" \
  "$submission_id" "$notary_log_path"
echo "Notarization log: $notary_log_path"

xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open \
  --context context:primary-signature \
  --verbose=4 "$dmg_path"

# Stapling changes the DMG, so the checksum must be generated afterwards.
(cd "$(dirname "$dmg_path")" && \
  shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$checksum_path")")

echo "Created notarized DMG: $dmg_path"
echo "SHA-256: $checksum_path"
