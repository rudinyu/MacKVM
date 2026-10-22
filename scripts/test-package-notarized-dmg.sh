#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
# This test runs under CI's main-repository lock but creates isolated fixture
# checkouts. Do not let fixture entrypoints inherit the main lock token.
unset MACKVM_BUILD_LOCK_DIR MACKVM_BUILD_LOCK_TOKEN
test_root="$(mktemp -d "${TMPDIR:-/tmp}/mackvm-notary-test.XXXXXX")"
test_root="$(cd "$test_root" && pwd -P)"
export MACKVM_TEST_ROOT="$test_root"
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

real_shasum="$(command -v shasum)"
[[ -n "$real_shasum" ]] || {
  echo "shasum is required for the notarized packaging test." >&2
  exit 1
}

mock_bin="$test_root/bin"
mock_notary="$test_root/mock_notary.py"
mkdir -p "$mock_bin"

cat > "$mock_notary" <<'PYMOCK'
#!/usr/bin/env python3
import os
import sys
import zipfile
from pathlib import Path

args = sys.argv[1:]
action = args[0] if args else ""
log_path = Path(os.environ["MACKVM_TEST_LOG"])

def log(message):
    with log_path.open("a", encoding="utf-8") as output:
        output.write(message + "\n")

log("helper " + " ".join(args))
notary_environment = (
    "MACOS_NOTARY_PROFILE",
    "MACOS_NOTARY_KEY_PATH",
    "MACOS_NOTARY_KEY_ID",
    "MACOS_NOTARY_ISSUER",
)
if action == "sign" and any(os.environ.get(name) for name in notary_environment):
    log("helper-sign-notary-env-present")
if action == "submit" and any(os.environ.get(name) for name in notary_environment):
    log("helper-submit-notary-env-present")

def option_value(option):
    try:
        return args[args.index(option) + 1]
    except (ValueError, IndexError):
        return ""

if action == "resolve-signing-identity":
    print(option_value("--identity") or os.environ["MACKVM_TEST_IDENTITY"])
    raise SystemExit(0)

if action == "resolve-auth":
    auth = os.environ.get("MACKVM_TEST_AUTH_KIND", "keychain-profile")
    if auth == "missing":
        print("no notary authentication is configured", file=sys.stderr)
        raise SystemExit(1)
    if option_value("--profile"):
        auth = "keychain-profile"
    print(auth)
    raise SystemExit(0)

if action == "sign":
    app_path = Path(args[1])
    (app_path / ".mackvm-test-signed").write_text("signed\n", encoding="utf-8")
    raise SystemExit(0)

if action == "submit":
    artifact = Path(args[1])
    if not artifact.exists() or artifact.is_dir():
        print(f"submitted artifact does not exist: {artifact}", file=sys.stderr)
        raise SystemExit(1)
    if artifact.suffix == ".pkg" and b"MACKVM-TEST-PKG-SIGNED:" not in artifact.read_bytes():
        print("submitted package does not contain the test Installer signature", file=sys.stderr)
        raise SystemExit(1)
    if artifact.suffix == ".zip":
        try:
            with zipfile.ZipFile(artifact) as archive:
                entries = archive.namelist()
        except (OSError, zipfile.BadZipFile):
            print("submitted app archive is not a valid ZIP", file=sys.stderr)
            raise SystemExit(1)
        if "MacKVM.app/.mackvm-test-signed" not in entries:
            print("submitted app archive does not contain the test Developer ID signature", file=sys.stderr)
            raise SystemExit(1)
    submission_id = "01234567-89ab-cdef-0123-456789abcdef"
    if os.environ.get("MACKVM_TEST_SUBMISSION", "accepted") == "timeout":
        print("Apple submission status: In Progress")
        print(f"Apple submission ID: {submission_id}")
        print("submission outcome may be unknown; do not resubmit automatically", file=sys.stderr)
        raise SystemExit(1)
    print("Apple submission status: Accepted")
    print(f"Apple submission ID: {submission_id}")
    raise SystemExit(0)

if action == "staple":
    artifact = Path(args[1])
    if artifact.is_dir():
        (artifact / ".mackvm-test-stapled").write_bytes(b"MACKVM-TEST-STAPLED\n")
    else:
        with artifact.open("ab") as output:
            output.write(b"\nMACKVM-TEST-STAPLED\n")
    raise SystemExit(0)

if action == "verify":
    artifact = Path(args[1])
    artifact_bytes = (
        (artifact / ".mackvm-test-stapled").read_bytes()
        if artifact.is_dir()
        else artifact.read_bytes()
    )
    if b"MACKVM-TEST-STAPLED" not in artifact_bytes:
        print("verification ran before stapling", file=sys.stderr)
        raise SystemExit(1)
    if artifact.suffix == ".app":
        if not (artifact / ".mackvm-test-signed").is_file():
            print("app verification ran without a Developer ID signature", file=sys.stderr)
            raise SystemExit(1)
        log("mock-app-gatekeeper spctl --assess --type execute")
        log("mock-app-ticket xcrun stapler validate")
    elif artifact.suffix == ".pkg":
        if b"MACKVM-TEST-PKG-SIGNED" not in artifact_bytes:
            print("package verification ran without an Installer signature", file=sys.stderr)
            raise SystemExit(1)
        log("mock-package-gatekeeper spctl --assess --type install")
        log("mock-package-ticket xcrun stapler validate")
    raise SystemExit(0)

print("unexpected helper action", file=sys.stderr)
raise SystemExit(90)
PYMOCK
chmod 755 "$mock_notary"

cat > "$mock_bin/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

tool="${0##*/}"
printf '%s %s\n' "$tool" "$*" >> "$MACKVM_TEST_LOG"

case "$tool" in
  security)
    [[ "${1:-}" == find-identity ]] || exit 90
    printf '1) TESTHASH "%s"\n' "$MACKVM_TEST_IDENTITY"
    printf '2) TESTINSTALLER "%s"\n' "$MACKVM_TEST_INSTALLER_IDENTITY"
    ;;
  plutil)
    if [[ "${1:-}" == -extract && "${2:-}" == CFBundleShortVersionString ]]; then
      printf '1.102.01\n'
    elif [[ "${1:-}" == -extract && "${2:-}" == CFBundleIdentifier ]]; then
      printf 'app.mackvm.MacKVM\n'
    fi
    ;;
  pkgbuild)
    output_path="${@: -1}"
    installer_identity=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --sign ]]; then
        installer_identity="${2:-}"
        shift 2
      else
        shift
      fi
    done
    [[ -n "$output_path" ]] || exit 97
    if [[ -n "$installer_identity" ]]; then
      printf 'MACKVM-TEST-PKG-SIGNED:%s\n' "$installer_identity" > "$output_path"
    else
      printf 'MACKVM-TEST-PKG-UNSIGNED\n' > "$output_path"
    fi
    ;;
  pkgutil)
    [[ "${1:-}" == --check-signature && -f "${2:-}" ]] || exit 98
    package_identity=""
    while IFS= read -r line; do
      case "$line" in
        MACKVM-TEST-PKG-SIGNED:*) package_identity="${line#MACKVM-TEST-PKG-SIGNED:}" ;;
      esac
    done < "$2"
    [[ -n "$package_identity" ]] || {
      echo "package does not have a test Installer signature" >&2
      exit 99
    }
    printf 'Status: signed by a certificate trusted by Mac OS X\n'
    printf '  1. %s\n' "$package_identity"
    ;;
  codesign)
    if [[ "${1:-}" == --display ]]; then
      printf 'Timestamp=2026-10-08T00:00:00Z\n'
    elif [[ "${1:-}" == --force ]]; then
      target=""
      for argument in "$@"; do target="$argument"; done
      printf '\nMACKVM-TEST-DMG-SIGNED\n' >> "$target"
    fi
    ;;
  ditto)
    source_path=""
    destination_path=""
    if [[ "${1:-}" == -c ]]; then
      [[ "${2:-}" == -k && "${3:-}" == --keepParent ]] || exit 91
      source_path="${4:-}"
      destination_path="${5:-}"
      [[ -d "$source_path" && -n "$destination_path" ]] || exit 91
      python3 - "$source_path" "$destination_path" <<'ZIPAPP'
import sys
import zipfile
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in source.rglob("*"):
        archive.write(path, (Path(source.name) / path.relative_to(source)).as_posix())
ZIPAPP
      exit 0
    fi
    if [[ "${1:-}" == --norsrc ]]; then shift; fi
    source_path="${1:-}"
    destination_path="${2:-}"
    [[ -d "$source_path" && -n "$destination_path" ]] || exit 91
    cp -R "$source_path" "$destination_path"
    ;;
  lipo)
    if [[ "${1:-}" == -create ]]; then
      output_path=""
      source_path=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == -output ]]; then
          output_path="${2:-}"
          shift 2
        else
          if [[ "$1" != -create ]]; then source_path="$1"; fi
          shift
        fi
      done
      [[ -n "$output_path" && -n "$source_path" ]] || exit 92
      cp "$source_path" "$output_path"
      printf '\nMACKVM-TEST-X86_64\n' >> "$output_path"
    fi
    ;;
  hdiutil)
    [[ "${1:-}" == create ]] || exit 93
    target=""
    source_path=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -srcfolder) source_path="${2:-}"; shift 2 ;;
        *) target="$1"; shift ;;
      esac
    done
    [[ -n "$target" ]] || exit 94
    [[ -d "$source_path" ]] || exit 94
    for entry in "$source_path"/*; do
      [[ -e "$entry" ]] || continue
      entry_name="${entry##*/}"
      printf 'dmg-entry %s\n' "$entry_name" >> "$MACKVM_TEST_LOG"
    done
    if [[ -d "$source_path/MacKVM.app" ]]; then
      [[ ! -e "$source_path/MacKVM.pkg" ]] || {
        echo "PKG was included in the app-only DMG" >&2
        exit 94
      }
      [[ -L "$source_path/Applications" && \
         "$(readlink "$source_path/Applications")" == /Applications ]] || {
        echo "Applications shortcut is missing or points to the wrong location" >&2
        exit 94
      }
      [[ -f "$source_path/MacKVM.app/.mackvm-test-stapled" ]] || {
        echo "The app was copied before its notarization ticket was stapled" >&2
        exit 94
      }
      for required_entry in INSTALL.md INSTALL.zh-TW.md UNINSTALL.md UNINSTALL.zh-TW.md Install\ MacKVM.command Uninstall\ MacKVM.command; do
        [[ -f "$source_path/$required_entry" ]] || {
          echo "Required app-only DMG entry is missing: $required_entry" >&2
          exit 94
        }
      done
      for executable_entry in 'Install MacKVM.command' 'Uninstall MacKVM.command' scripts/install-app.sh scripts/uninstall-app.sh; do
        [[ -x "$source_path/$executable_entry" ]] || {
          echo "App-only DMG entry is not executable: $executable_entry" >&2
          exit 94
        }
        printf 'dmg-executable %s\n' "$executable_entry" >> "$MACKVM_TEST_LOG"
      done
      grep -F 'scripts/install-app.sh' "$source_path/Install MacKVM.command" >/dev/null || exit 94
      grep -F 'scripts/uninstall-app.sh' "$source_path/Uninstall MacKVM.command" >/dev/null || exit 94
      grep -F -- '--source "$dmg_dir/MacKVM.app"' "$source_path/Install MacKVM.command" >/dev/null || exit 94
      grep -F 'Install MacKVM.command' "$source_path/INSTALL.md" >/dev/null || exit 94
      grep -F 'Uninstall MacKVM.command' "$source_path/INSTALL.zh-TW.md" >/dev/null || exit 94
      grep -F -- '--purge' "$source_path/UNINSTALL.md" >/dev/null || exit 94
      grep -F -- '--purge' "$source_path/UNINSTALL.zh-TW.md" >/dev/null || exit 94
      # Finder launches these files from a mounted read-only volume. Run their
      # dry-run paths against isolated temp targets to exercise relative paths
      # and argument quoting without changing the host's Applications folder.
      restore_staging_permissions() {
        find "$source_path" -type f -exec chmod u+w {} +
        find "$source_path" -type d -exec chmod u+w {} +
      }
      trap restore_staging_permissions EXIT
      chmod -R a-w "$source_path"
      "$source_path/Install MacKVM.command" --dry-run \
        --target-dir "$MACKVM_TEST_ROOT/install target" >> "$MACKVM_TEST_LOG"
      "$source_path/Uninstall MacKVM.command" --dry-run \
        --target-dir "$MACKVM_TEST_ROOT/uninstall target" >> "$MACKVM_TEST_LOG"
      restore_staging_permissions
      trap - EXIT
    else
      [[ ! -e "$source_path/Install MacKVM.command" && ! -e "$source_path/Uninstall MacKVM.command" ]] || {
        echo "Finder command wrappers appeared in the optional PKG layout" >&2
        exit 94
      }
    fi
    printf 'MACKVM-TEST-DMG\n' > "$target"
    ;;
  xcrun)
    if [[ "${1:-}" == notarytool && "${2:-}" == log ]]; then
      exit 1
    fi
    echo "unexpected xcrun operation" >&2
    exit 95
    ;;
  shasum)
    "$MACKVM_TEST_REAL_SHASUM" "$@"
    ;;
  *)
    echo "unexpected mocked command: $tool" >&2
    exit 96
    ;;
esac
MOCK
chmod 755 "$mock_bin/mock-command"
for command_name in security plutil pkgbuild pkgutil codesign ditto lipo hdiutil xcrun shasum; do
  ln -s mock-command "$mock_bin/$command_name"
done

export PATH="$mock_bin:$PATH"
export MACKVM_TEST_REAL_SHASUM="$real_shasum"
export MACKVM_NOTARIZATION_TOOL="$mock_notary"
export MACKVM_TEST_IDENTITY="Developer ID Application: MacKVM Test (ABCDE12345)"
export MACKVM_TEST_INSTALLER_IDENTITY="Developer ID Installer: MacKVM Test (ABCDE12345)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected output to contain: $2" ;;
  esac
}

assert_file_contains() {
  grep -F -- "$2" "$1" >/dev/null || fail "expected $1 to contain: $2"
}

assert_file_lacks() {
  if grep -F -- "$2" "$1" >/dev/null; then
    fail "expected $1 not to contain: $2"
  fi
}

assert_order() {
  local log_path="$1"
  local first="$2"
  local second="$3"
  local first_line
  local second_line
  first_line="$(grep -nF -- "$first" "$log_path" | head -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -nF -- "$second" "$log_path" | head -n 1 | cut -d: -f1 || true)"
  [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] || {
    fail "expected '$first' before '$second' in $log_path"
  }
}

new_project() {
  local name="$1"
  case_root="$test_root/$name"
  fixture_project="$case_root/project"
  fixture_scripts="$fixture_project/scripts"
  export MACKVM_TEST_LOG="$case_root/tool-calls.log"
  mkdir -p "$fixture_scripts/lib" "$fixture_scripts/dmg" "$fixture_project/Resources"
  : > "$MACKVM_TEST_LOG"

  cp "$project_root/scripts/package-notarized-dmg.sh" "$fixture_scripts/"
  cp "$project_root/scripts/package-dmg.sh" "$fixture_scripts/"
  cp "$project_root/scripts/compose-dmg.sh" "$fixture_scripts/"
  cp "$project_root/scripts/install-app.sh" "$fixture_scripts/"
  cp "$project_root/scripts/uninstall-app.sh" "$fixture_scripts/"
  cp "$project_root/scripts/dmg/Install MacKVM.command" "$fixture_scripts/dmg/"
  cp "$project_root/scripts/dmg/Uninstall MacKVM.command" "$fixture_scripts/dmg/"
  cp "$project_root/scripts/with-build-lock.sh" "$fixture_scripts/"
  cp "$project_root/scripts/lib/build-environment.sh" "$fixture_scripts/lib/"
  cat > "$fixture_scripts/clean-build.sh" <<'CLEAN'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MACOS_NOTARY_PROFILE:-}${MACOS_NOTARY_KEY_PATH:-}${MACOS_NOTARY_KEY_ID:-}${MACOS_NOTARY_ISSUER:-}" ]]; then
  printf 'build-leaked-notary-env\n' >> "$MACKVM_TEST_LOG"
  exit 1
fi
printf 'clean-build\n' >> "$MACKVM_TEST_LOG"
CLEAN
  cat > "$fixture_scripts/build-app.sh" <<'BUILD'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MACOS_NOTARY_PROFILE:-}${MACOS_NOTARY_KEY_PATH:-}${MACOS_NOTARY_KEY_ID:-}${MACOS_NOTARY_ISSUER:-}" ]]; then
  printf 'build-leaked-notary-env\n' >> "$MACKVM_TEST_LOG"
  exit 1
fi
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) arch="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$arch" ]] || exit 90
app="$project_root/dist/$arch/MacKVM.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
printf 'fake app %s\n' "$arch" > "$app/Contents/MacOS/MacKVM"
  chmod 755 "$app/Contents/MacOS/MacKVM"
printf 'fake plist\n' > "$app/Contents/Info.plist"
BUILD
  cat > "$fixture_scripts/verify-release.sh" <<'VERIFY'
#!/usr/bin/env bash
set -euo pipefail
printf 'project-verify %s\n' "$*" >> "$MACKVM_TEST_LOG"
[[ "$*" == *--require-developer-id* ]] || exit 91
app_path=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --app ]]; then app_path="$2"; shift 2; else shift; fi
done
[[ -f "$app_path/.mackvm-test-signed" ]] || exit 92
VERIFY
  cp "$project_root/INSTALL.md" "$fixture_project/INSTALL.md"
  cp "$project_root/INSTALL.zh-TW.md" "$fixture_project/INSTALL.zh-TW.md"
  cp "$project_root/UNINSTALL.md" "$fixture_project/UNINSTALL.md"
  cp "$project_root/UNINSTALL.zh-TW.md" "$fixture_project/UNINSTALL.zh-TW.md"
  chmod 755 "$fixture_scripts"/*.sh "$fixture_scripts/dmg"/*.command
}

# A path-like version must be rejected before the composer creates its dist
# staging directory or constructs a version-derived output path.
new_project invalid-dmg-version
fixture_pkg="$fixture_project/fixture.pkg"
printf 'fixture package\n' > "$fixture_pkg"
if output="$(
  "$fixture_scripts/compose-dmg.sh" \
    --pkg "$fixture_pkg" \
    --version ../../../../escape \
    --arch universal 2>&1
)"; then
  fail "path-like DMG version was unexpectedly accepted"
else
  status=$?
fi
[[ "$status" -eq 2 ]] || fail "path-like DMG version returned $status instead of 2"
assert_contains "$output" "Invalid version"
[[ ! -e "$fixture_project/dist" ]] || \
  fail "path-like DMG version mutated the fixture dist directory"

# Missing credentials are resolved before any build or packaging command can
# run. An explicit identity alone must not trigger an authenticated release.
new_project missing-auth
export MACKVM_TEST_AUTH_KIND=missing
config_path="$case_root/empty-notarization.env"
: > "$config_path"
chmod 600 "$config_path"
if output="$(
  "$fixture_scripts/package-notarized-dmg.sh" \
    --arch universal \
    --sign "$MACKVM_TEST_IDENTITY" \
    --config "$config_path" 2>&1
)"; then
  fail "notarized packaging unexpectedly continued without notary credentials"
else
  status=$?
fi
[[ "$status" -eq 2 ]] || fail "missing auth returned $status instead of 2"
assert_contains "$output" "Apple notary authentication is unavailable or invalid"
assert_file_lacks "$MACKVM_TEST_LOG" "clean-build"
assert_file_lacks "$MACKVM_TEST_LOG" "helper submit"

# Empty equals-form overrides must fail parsing rather than falling back to
# configured values for a release.
new_project empty-overrides
for invalid_kind in sign installer-sign profile config; do
  case "$invalid_kind" in
    sign)
      invalid_arguments=("$fixture_scripts/package-notarized-dmg.sh" --sign=)
      ;;
    installer-sign)
      invalid_arguments=("$fixture_scripts/package-notarized-dmg.sh" --sign "$MACKVM_TEST_IDENTITY" --installer-sign=)
      ;;
    profile)
      invalid_arguments=("$fixture_scripts/package-notarized-dmg.sh" --sign "$MACKVM_TEST_IDENTITY" --keychain-profile=)
      ;;
    config)
      invalid_arguments=("$fixture_scripts/package-notarized-dmg.sh" --sign "$MACKVM_TEST_IDENTITY" --keychain-profile profile --config=)
      ;;
  esac
  if output="$("${invalid_arguments[@]}" 2>&1)"; then
    fail "empty $invalid_kind override was unexpectedly accepted"
  else
    status=$?
  fi
  [[ "$status" -eq 2 ]] || fail "empty $invalid_kind override returned $status instead of 2"
done
[[ ! -s "$MACKVM_TEST_LOG" ]] || fail "empty overrides reached the helper or packaging path"

# The default release path submits, staples, and verifies the signed app before
# composing the app-only image. The mounted image must include the working
# Finder wrappers, executable shared helpers, bilingual guides, and no PKG.
new_project accepted-app-only
export MACKVM_TEST_AUTH_KIND=keychain-profile
export MACKVM_TEST_SUBMISSION=accepted
output="$(
  "$fixture_scripts/package-notarized-dmg.sh" \
    --arch universal \
    --sign "$MACKVM_TEST_IDENTITY" \
    --keychain-profile cli-profile 2>&1
)" || fail "mocked app-only release failed: $output"
assert_contains "$output" "Created notarized app: $fixture_project/dist/universal/MacKVM.app"
assert_contains "$output" "Created notarized DMG: $fixture_project/dist/MacKVM-1.102.01-universal.dmg"
assert_file_lacks "$MACKVM_TEST_LOG" "pkgbuild"
assert_file_lacks "$MACKVM_TEST_LOG" "pkgutil"
assert_file_lacks "$MACKVM_TEST_LOG" "clean-build"
app_path="$fixture_project/dist/universal/MacKVM.app"
app_archive_path="$fixture_project/.build/notarization/MacKVM-1.102.01-universal.app.zip"
dmg_path="$fixture_project/dist/MacKVM-1.102.01-universal.dmg"
assert_order "$MACKVM_TEST_LOG" "helper sign $app_path" "ditto -c -k --keepParent $app_path $app_archive_path"
assert_order "$MACKVM_TEST_LOG" "ditto -c -k --keepParent $app_path $app_archive_path" "helper submit $app_archive_path"
assert_order "$MACKVM_TEST_LOG" "helper submit $app_archive_path" "helper staple $app_path"
assert_order "$MACKVM_TEST_LOG" "helper staple $app_path" "helper verify $app_path"
assert_file_lacks "$MACKVM_TEST_LOG" "helper submit $app_path"
assert_order "$MACKVM_TEST_LOG" "mock-app-ticket xcrun stapler validate" "hdiutil create"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-entry MacKVM.app"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-entry Applications"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-entry Install MacKVM.command"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-entry Uninstall MacKVM.command"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-entry INSTALL.md"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-entry INSTALL.zh-TW.md"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-entry UNINSTALL.md"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-entry UNINSTALL.zh-TW.md"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-executable Install MacKVM.command"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-executable Uninstall MacKVM.command"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-executable scripts/install-app.sh"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-executable scripts/uninstall-app.sh"
assert_file_lacks "$MACKVM_TEST_LOG" "dmg-entry MacKVM.pkg"
assert_order "$MACKVM_TEST_LOG" "hdiutil create" "codesign --force --timestamp --sign"
assert_order "$MACKVM_TEST_LOG" "helper submit $app_archive_path" "helper submit $dmg_path"
assert_order "$MACKVM_TEST_LOG" "helper staple $dmg_path" "helper verify $dmg_path"
[[ -f "$fixture_project/dist/MacKVM-1.102.01-universal.app.notary.json" ]] || \
  fail "app notarization metadata was not retained"
[[ ! -e "$app_archive_path" ]] || fail "temporary app notarization archive was not removed after success"
[[ -f "$dmg_path.sha256" ]] || fail "app-only DMG checksum was not created"
[[ ! -f "$fixture_project/dist/MacKVM-1.102.01-universal.pkg" ]] || \
  fail "app-only release unexpectedly created a PKG"
unset MACKVM_TEST_AUTH_KIND MACKVM_TEST_SUBMISSION

# A successful release signs the app and package, notarizes and staples the
# standalone package before composing the DMG, then independently notarizes the
# top-level container. Both checksums follow staple and verification.
new_project accepted-log-failure
export MACKVM_TEST_AUTH_KIND=keychain-profile
export MACKVM_TEST_SUBMISSION=accepted
export MACOS_NOTARY_PROFILE=ambient-test-profile
export MACOS_NOTARY_KEY_PATH=/private/tmp/mackvm-test-only-key.p8
export MACOS_NOTARY_KEY_ID=TESTKEYID
export MACOS_NOTARY_ISSUER=TESTISSUER
config_path="$case_root/notarization.env"
: > "$config_path"
chmod 600 "$config_path"
output="$(
  "$fixture_scripts/package-notarized-dmg.sh" \
    --pkg \
    --arch universal \
    --sign "$MACKVM_TEST_IDENTITY" \
    --keychain-profile cli-profile \
    --config "$config_path" \
    --timeout 2h 2>&1
)" || fail "accepted mocked release failed: $output"
assert_contains "$output" "Apple submission status: Accepted"
assert_contains "$output" "Apple submission ID: 01234567-89ab-cdef-0123-456789abcdef"
assert_contains "$output" "The installer package notarization log was unavailable; continuing with the accepted ticket."
assert_contains "$output" "The disk image notarization log was unavailable; continuing with the accepted ticket."
assert_file_contains "$MACKVM_TEST_LOG" "helper resolve-signing-identity --config $config_path --identity $MACKVM_TEST_IDENTITY"
assert_file_contains "$MACKVM_TEST_LOG" "helper resolve-auth --auth auto --project-root "
assert_file_contains "$MACKVM_TEST_LOG" "--config $config_path --profile cli-profile"
assert_file_contains "$MACKVM_TEST_LOG" "helper submit"
assert_file_contains "$MACKVM_TEST_LOG" "pkgbuild --component "
assert_file_contains "$MACKVM_TEST_LOG" "--sign $MACKVM_TEST_INSTALLER_IDENTITY"
assert_file_contains "$MACKVM_TEST_LOG" "pkgutil --check-signature "
assert_file_contains "$MACKVM_TEST_LOG" "helper-submit-notary-env-present"
assert_file_lacks "$MACKVM_TEST_LOG" "helper-sign-notary-env-present"
assert_file_lacks "$MACKVM_TEST_LOG" "build-leaked-notary-env"
assert_file_contains "$MACKVM_TEST_LOG" "--auth keychain-profile"
assert_file_contains "$MACKVM_TEST_LOG" "--profile cli-profile"
pkg_path="$fixture_project/dist/MacKVM-1.102.01-universal.pkg"
pkg_checksum_path="$pkg_path.sha256"
dmg_path="$fixture_project/dist/MacKVM-1.102.01-universal.dmg"
checksum_path="$dmg_path.sha256"
assert_order "$MACKVM_TEST_LOG" "helper sign" "pkgbuild"
assert_order "$MACKVM_TEST_LOG" "pkgutil --check-signature" "helper submit $pkg_path"
assert_order "$MACKVM_TEST_LOG" "helper submit $pkg_path" "helper staple $pkg_path"
assert_order "$MACKVM_TEST_LOG" "helper staple $pkg_path" "helper verify $pkg_path"
assert_order "$MACKVM_TEST_LOG" "helper verify $pkg_path" "mock-package-gatekeeper spctl --assess --type install"
assert_order "$MACKVM_TEST_LOG" "mock-package-gatekeeper spctl --assess --type install" "mock-package-ticket xcrun stapler validate"
assert_order "$MACKVM_TEST_LOG" "mock-package-ticket xcrun stapler validate" "shasum -a 256 MacKVM-1.102.01-universal.pkg"
assert_order "$MACKVM_TEST_LOG" "shasum -a 256 MacKVM-1.102.01-universal.pkg" "hdiutil create"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-entry MacKVM.pkg"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-entry INSTALL.md"
assert_file_contains "$MACKVM_TEST_LOG" "dmg-entry INSTALL.zh-TW.md"
assert_file_lacks "$MACKVM_TEST_LOG" "dmg-entry MacKVM.app"
assert_file_lacks "$MACKVM_TEST_LOG" ".command"
assert_order "$MACKVM_TEST_LOG" "helper submit $pkg_path" "helper submit $dmg_path"
assert_order "$MACKVM_TEST_LOG" "helper staple $dmg_path" "helper verify $dmg_path"
last_dmg_shasum_line="$(grep -nF 'shasum -a 256 MacKVM-1.102.01-universal.dmg' "$MACKVM_TEST_LOG" | tail -n 1 | cut -d: -f1)"
dmg_verify_line="$(grep -nF "helper verify $dmg_path" "$MACKVM_TEST_LOG" | tail -n 1 | cut -d: -f1)"
[[ "$dmg_verify_line" -lt "$last_dmg_shasum_line" ]] || \
  fail "final DMG checksum was not written after staple and verification"
[[ -f "$pkg_checksum_path" ]] || fail "standalone package checksum was not created"
[[ -f "$checksum_path" ]] || fail "final checksum sidecar was not created"
(cd "$(dirname "$pkg_path")" && "$real_shasum" -a 256 -c "$(basename "$pkg_checksum_path")") || \
  fail "package checksum did not match the stapled PKG"
(cd "$(dirname "$dmg_path")" && "$real_shasum" -a 256 -c "$(basename "$checksum_path")") || \
  fail "final checksum did not match the stapled DMG"
python3 - "$pkg_path.notary.json" "$dmg_path.notary.json" <<'JSONCHECK'
import json
import sys
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as source:
        metadata = json.load(source)
    assert metadata == {
        "id": "01234567-89ab-cdef-0123-456789abcdef",
        "status": "Accepted",
    }
JSONCHECK
[[ ! -d "$fixture_project/dist/.staging" ]] || fail "staging directory was left behind"
[[ ! -e "$fixture_project/.mackvm-build.lock" ]] || \
  fail "successful notarized packaging left the shared build lock behind"
unset MACOS_NOTARY_PROFILE MACOS_NOTARY_KEY_PATH MACOS_NOTARY_KEY_ID MACOS_NOTARY_ISSUER

# When the helper resolves a complete legacy API-key setup, the adapter passes
# that kind explicitly to both submit calls without exposing key values.
new_project api-key-auth
export MACKVM_TEST_AUTH_KIND=api-key
export MACKVM_TEST_SUBMISSION=accepted
output="$(
  "$fixture_scripts/package-notarized-dmg.sh" \
    --pkg \
    --arch arm64 \
    --sign "$MACKVM_TEST_IDENTITY" \
    --timeout 30 2>&1
)" || fail "mocked API-key release failed: $output"
assert_contains "$output" "Apple submission status: Accepted"
assert_file_contains "$MACKVM_TEST_LOG" "helper resolve-auth --auth auto --project-root "
assert_file_contains "$MACKVM_TEST_LOG" "--auth api-key"
assert_file_contains "$MACKVM_TEST_LOG" "--timeout 30s"
assert_file_lacks "$MACKVM_TEST_LOG" "xcrun notarytool log"
[[ -f "$fixture_project/dist/MacKVM-1.102.01-arm64.pkg.notary.json" && \
   -f "$fixture_project/dist/MacKVM-1.102.01-arm64.dmg.notary.json" ]] || \
  fail "submission metadata was not retained for both artifacts with API-key authentication"

# A timeout or unknown result is reported once and never proceeds to staple.
new_project timeout
export MACKVM_TEST_AUTH_KIND=keychain-profile
export MACKVM_TEST_SUBMISSION=timeout
if output="$(
  "$fixture_scripts/package-notarized-dmg.sh" \
    --pkg \
    --arch arm64 \
    --sign "$MACKVM_TEST_IDENTITY" \
    --keychain-profile cli-profile 2>&1
)"; then
  fail "timed-out mocked release unexpectedly succeeded"
else
  status=$?
fi
[[ "$status" -eq 1 ]] || fail "unknown submission returned $status instead of 1"
assert_contains "$output" "Apple submission status: In Progress"
submit_count="$(grep -c '^helper submit ' "$MACKVM_TEST_LOG" || true)"
[[ "$submit_count" -eq 1 ]] || fail "expected exactly one submission attempt, found $submit_count"
assert_file_lacks "$MACKVM_TEST_LOG" "helper staple"
assert_file_lacks "$MACKVM_TEST_LOG" "helper verify"
[[ ! -f "$fixture_project/dist/MacKVM-1.102.01-arm64.pkg.sha256" ]] || \
  fail "a package checksum was left behind for an unaccepted submission"
[[ ! -f "$fixture_project/dist/MacKVM-1.102.01-arm64.dmg" ]] || \
  fail "a DMG was composed for an unaccepted package submission"

echo "Notarized app-only and optional PKG DMG adapter tests passed."
