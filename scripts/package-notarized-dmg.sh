#!/usr/bin/env bash
set +x
set -euo pipefail

project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_root"

source "$project_root/scripts/lib/build-environment.sh"
original_arguments=("$@")
original_argument_count=$#

usage() {
  cat >&2 <<'EOF'
Usage: scripts/package-notarized-dmg.sh \
       [--sign "Developer ID Application: …"] \
       [--installer-sign "Developer ID Installer: …"] \
       [--keychain-profile PROFILE] [--auth auto|keychain-profile|api-key] \
       [--config PATH] [--arch universal|arm64|x86_64] [--timeout DURATION]

Builds a Developer ID-signed app and Installer-signed PKG, submits and staples
the PKG, then embeds it in a separately signed and notarized DMG. The PKG is
independently installable and has its own checksum and notary metadata. The app
signing identity and notary authentication default to the shared Codex
configuration at ~/.config/codex/notarization.env; the Installer identity is
derived from the app identity unless --installer-sign overrides it.

This is the distribution path. For local ad-hoc testing, use:
  scripts/package-dmg.sh --arch universal
EOF
}

requested_arch="universal"
signing_identity_override=""
installer_signing_identity_override=""
notary_profile_override=""
notary_auth="auto"
notary_timeout="2h"
notarization_config=""

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --sign)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      signing_identity_override="$2"
      shift 2
      ;;
    --sign=*)
      signing_identity_override="${1#--sign=}"
      [[ -n "$signing_identity_override" ]] || { usage; exit 2; }
      shift
      ;;
    --installer-sign)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      installer_signing_identity_override="$2"
      shift 2
      ;;
    --installer-sign=*)
      installer_signing_identity_override="${1#--installer-sign=}"
      [[ -n "$installer_signing_identity_override" ]] || { usage; exit 2; }
      shift
      ;;
    --keychain-profile)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      notary_profile_override="$2"
      shift 2
      ;;
    --keychain-profile=*)
      notary_profile_override="${1#--keychain-profile=}"
      [[ -n "$notary_profile_override" ]] || { usage; exit 2; }
      shift
      ;;
    --auth)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      notary_auth="$2"
      shift 2
      ;;
    --auth=*)
      notary_auth="${1#--auth=}"
      [[ -n "$notary_auth" ]] || { usage; exit 2; }
      shift
      ;;
    --config)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      notarization_config="$2"
      shift 2
      ;;
    --config=*)
      notarization_config="${1#--config=}"
      [[ -n "$notarization_config" ]] || { usage; exit 2; }
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

case "$notary_auth" in
  auto|keychain-profile|api-key)
    ;;
  *)
    echo "Unsupported notary authentication mode: $notary_auth" >&2
    exit 2
    ;;
esac

if [[ ! "$notary_timeout" =~ ^[1-9][0-9]*([smh])?$ ]]; then
  echo "Invalid notarization timeout: $notary_timeout" >&2
  echo "Use positive seconds or an integer followed by s, m, or h (for example, 2h)." >&2
  exit 2
fi
submission_timeout="$notary_timeout"
if [[ "$submission_timeout" =~ ^[0-9]+$ ]]; then
  submission_timeout="${submission_timeout}s"
fi

# Hold the shared lock through signing, Apple submissions, stapling, verification,
# and DMG composition. Nested package/build scripts reuse this lock token.
if [[ "$original_argument_count" -eq 0 ]]; then
  mackvm_enter_build_lock "$project_root" "$project_root/scripts/package-notarized-dmg.sh"
else
  mackvm_enter_build_lock "$project_root" "$project_root/scripts/package-notarized-dmg.sh" "${original_arguments[@]}"
fi

notarization_tool="${MACKVM_NOTARIZATION_TOOL:-${HOME:-}/.codex/skills/macos-notarization-release/scripts/macos_notarization.py}"
if [[ ! -f "$notarization_tool" ]]; then
  echo "Shared macOS notarization helper was not found: $notarization_tool" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required to run the shared macOS notarization helper." >&2
  exit 2
fi

identity_arguments=(resolve-signing-identity)
if [[ -n "$notarization_config" ]]; then
  identity_arguments+=(--config "$notarization_config")
fi
if [[ -n "$signing_identity_override" ]]; then
  identity_arguments+=(--identity "$signing_identity_override")
fi
if ! signing_identity="$(python3 "$notarization_tool" "${identity_arguments[@]}")"; then
  echo "A Developer ID Application identity is unavailable; configure MACOS_SIGNING_IDENTITY or pass --sign." >&2
  exit 2
fi
if [[ -z "$signing_identity" || "$signing_identity" == *$'\n'* ]]; then
  echo "The shared macOS notarization helper did not return one signing identity." >&2
  exit 2
fi
case "$signing_identity" in
  "Developer ID Application:"*)
    ;;
  *)
    echo "The signing identity must be a Developer ID Application identity." >&2
    exit 2
    ;;
esac

if [[ -n "$installer_signing_identity_override" ]]; then
  installer_signing_identity="$installer_signing_identity_override"
else
  installer_signing_identity="${signing_identity/Developer ID Application:/Developer ID Installer:}"
fi
case "$installer_signing_identity" in
  "Developer ID Installer:"*)
    ;;
  *)
    echo "The package identity must be a Developer ID Installer identity." >&2
    exit 2
    ;;
esac

auth_arguments=(resolve-auth --auth "$notary_auth")
auth_arguments+=(--project-root "$project_root")
if [[ -n "$notarization_config" ]]; then
  auth_arguments+=(--config "$notarization_config")
fi
if [[ -n "$notary_profile_override" ]]; then
  auth_arguments+=(--profile "$notary_profile_override")
fi
if ! resolved_auth="$(python3 "$notarization_tool" "${auth_arguments[@]}")"; then
  echo "Apple notary authentication is unavailable or invalid; configure it in ~/.config/codex/notarization.env or pass a CLI override." >&2
  exit 2
fi
case "$resolved_auth" in
  keychain-profile|api-key)
    ;;
  *)
    echo "The shared macOS notarization helper returned an unsupported authentication mode." >&2
    exit 2
    ;;
esac

identity_list="$(security find-identity -v 2>/dev/null || true)"
if ! grep -F -- "\"$signing_identity\"" <<<"$identity_list" >/dev/null; then
  echo "Developer ID Application identity was not found in the login Keychain:" >&2
  echo "  $signing_identity" >&2
  exit 1
fi
if ! grep -F -- "\"$installer_signing_identity\"" <<<"$identity_list" >/dev/null; then
  echo "Developer ID Installer identity was not found in the login Keychain:" >&2
  echo "  $installer_signing_identity" >&2
  exit 1
fi

package_arguments=(
  --arch "$requested_arch"
  --sign "$signing_identity"
  --installer-sign "$installer_signing_identity"
  --require-developer-id
  --use-shared-signing
  --pkg-only
)
if [[ -n "$notarization_config" ]]; then
  package_arguments+=(--notarization-config "$notarization_config")
fi
env \
  -u MACOS_NOTARY_PROFILE \
  -u MACOS_NOTARY_KEY_PATH \
  -u MACOS_NOTARY_KEY_ID \
  -u MACOS_NOTARY_ISSUER \
  ./scripts/package-dmg.sh "${package_arguments[@]}"

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
pkg_path="$project_root/dist/MacKVM-$version-$requested_arch.pkg"
dmg_path="$project_root/dist/MacKVM-$version-$requested_arch.dmg"
pkg_checksum_path="$pkg_path.sha256"
pkg_notary_log_path="$pkg_path.notary.json"
dmg_checksum_path="$dmg_path.sha256"
dmg_notary_log_path="$dmg_path.notary.json"

[[ -f "$pkg_path" ]] || {
  echo "Installer package was not created: $pkg_path" >&2
  exit 1
}
package_signature="$(pkgutil --check-signature "$pkg_path")"
grep -F -- "$installer_signing_identity" <<<"$package_signature" >/dev/null || {
  echo "The package signature does not match the requested Developer ID Installer identity." >&2
  exit 1
}

# A pending or failed package submission must never leave a checksum that looks
# like a successfully notarized standalone installer.
rm -f -- "$pkg_checksum_path" "$pkg_notary_log_path" \
  "$dmg_path" "$dmg_checksum_path" "$dmg_notary_log_path"

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

print_submission_summary() {
  local output="$1"
  local line
  while IFS= read -r line; do
    case "$line" in
      "Apple submission status:"*|"Apple submission ID:"*)
        printf '%s\n' "$line"
        ;;
    esac
  done <<<"$output"
}

write_submission_metadata() {
  local metadata_path="$1"
  local submission_id="$2"
  local submission_status="$3"
  cat >"$metadata_path" <<EOF
{
  "id": "$submission_id",
  "status": "$submission_status"
}
EOF
}

submit_staple_verify() {
  local artifact_path="$1"
  local metadata_path="$2"
  local checksum_path="$3"
  local artifact_label="$4"
  local -a submission_arguments
  local submission_output
  local submission_status
  local submission_id

  submission_arguments=(
    submit "$artifact_path"
    --authorized
    --wait
    --auth "$resolved_auth"
    --timeout "$submission_timeout"
    --project-root "$project_root"
  )
  if [[ -n "$notary_profile_override" ]]; then
    submission_arguments+=(--profile "$notary_profile_override")
  fi
  if [[ -n "$notarization_config" ]]; then
    submission_arguments+=(--config "$notarization_config")
  fi

  if submission_output="$(python3 "$notarization_tool" "${submission_arguments[@]}")"; then
    submission_status="$(sed -n 's/^Apple submission status:[[:space:]]*//p' <<<"$submission_output")"
    submission_id="$(sed -n 's/^Apple submission ID:[[:space:]]*//p' <<<"$submission_output")"
    print_submission_summary "$submission_output"
    if [[ "$submission_status" != "Accepted" || ! "$submission_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
      echo "The shared helper did not report one accepted Apple submission with a valid ID for $artifact_label." >&2
      exit 1
    fi
  else
    submission_status="$(sed -n 's/^Apple submission status:[[:space:]]*//p' <<<"$submission_output")"
    submission_id="$(sed -n 's/^Apple submission ID:[[:space:]]*//p' <<<"$submission_output")"
    print_submission_summary "$submission_output"
    echo "Apple notarization of the $artifact_label did not finish with an accepted result. Inspect the existing submission; do not submit this artifact again automatically." >&2
    exit 1
  fi

  # When an explicitly supplied Keychain profile can fetch the Apple log, keep
  # it as useful provenance. Log retrieval is optional and never blocks staple.
  if [[ -n "$notary_profile_override" ]]; then
    if xcrun notarytool log \
      --keychain-profile "$notary_profile_override" \
      "$submission_id" "$metadata_path" && [[ -s "$metadata_path" ]]; then
      echo "Notarization log: $metadata_path"
    else
      write_submission_metadata "$metadata_path" "$submission_id" "$submission_status"
      echo "The $artifact_label notarization log was unavailable; continuing with the accepted ticket." >&2
      echo "Submission metadata: $metadata_path"
    fi
  else
    write_submission_metadata "$metadata_path" "$submission_id" "$submission_status"
    echo "Submission metadata: $metadata_path"
  fi

  python3 "$notarization_tool" staple "$artifact_path"
  # The shared helper verifies package signatures, Gatekeeper's install
  # assessment for PKGs, and the stapled ticket (including stapler validate).
  python3 "$notarization_tool" verify "$artifact_path"

  (cd "$(dirname "$artifact_path")" && \
    shasum -a 256 "$(basename "$artifact_path")" > "$(basename "$checksum_path")")
}

# The package is independently signed, submitted, stapled, and verified before
# the DMG is composed, so the container carries the exact standalone artifact.
submit_staple_verify \
  "$pkg_path" "$pkg_notary_log_path" "$pkg_checksum_path" "installer package"

./scripts/compose-dmg.sh \
  --pkg "$pkg_path" \
  --version "$version" \
  --arch "$requested_arch"
[[ -f "$dmg_path" ]] || {
  echo "DMG was not created: $dmg_path" >&2
  exit 1
}
rm -f -- "$dmg_checksum_path" "$dmg_notary_log_path"

# The app and PKG are signed before composition; the DMG remains independently
# signed and notarized as the top-level release container.
codesign --force --timestamp --sign "$signing_identity" "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"
assert_secure_timestamp "$dmg_path"

submit_staple_verify \
  "$dmg_path" "$dmg_notary_log_path" "$dmg_checksum_path" "disk image"

echo "Created notarized PKG: $pkg_path"
echo "SHA-256: $pkg_checksum_path"
echo "Created notarized DMG: $dmg_path"
echo "SHA-256: $dmg_checksum_path"
