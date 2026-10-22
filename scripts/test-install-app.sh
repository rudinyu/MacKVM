#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
installer="$project_root/scripts/install-app.sh"
test_root="$(mktemp -d /private/tmp/mackvm-installer-test.XXXXXX)"
cleanup() {
  /bin/rm -rf -- "$test_root"
}
trap cleanup EXIT

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/codesign" <<'CODESIGN'
#!/usr/bin/env bash
set -euo pipefail

app_path="${!#}"
case "${1:-}" in
  --verify)
    exit 0
    ;;
  --display)
    printf 'TeamIdentifier=%s\n' "$(<"$app_path/Contents/.test-team")"
    ;;
  -d)
    [[ "${2:-}" == "-r-" ]] || exit 64
    printf 'designated => %s\n' "$(<"$app_path/Contents/.test-requirement")" >&2
    ;;
  *)
    echo "Unexpected codesign invocation: $*" >&2
    exit 64
    ;;
esac
CODESIGN
cat > "$fake_bin/pgrep" <<'PGREP'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == "-f" ]] || exit 64
exit "${MACKVM_TEST_PGREP_STATUS:-1}"
PGREP
cat > "$fake_bin/tccutil" <<'TCCUTIL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MACKVM_TEST_TCC_LOG"
exit 0
TCCUTIL
chmod 755 "$fake_bin/codesign" "$fake_bin/pgrep" "$fake_bin/tccutil"
export PATH="$fake_bin:$PATH"
export MACKVM_TEST_TCC_LOG="$test_root/tccutil.log"

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

create_app() {
  local app_path="$1"
  local version="$2"
  local team_identifier="$3"
  local requirement="$4"
  mkdir -p "$app_path/Contents/MacOS"
  cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.mackvm.MacKVM</string></dict></plist>
PLIST
  printf '#!/bin/sh\nexit 0\n' > "$app_path/Contents/MacOS/MacKVM"
  chmod 755 "$app_path/Contents/MacOS/MacKVM"
  printf '%s\n' "$version" > "$app_path/Contents/.test-version"
  printf '%s\n' "$team_identifier" > "$app_path/Contents/.test-team"
  printf '%s\n' "$requirement" > "$app_path/Contents/.test-requirement"
}

run_installer() {
  "$installer" --source "$source_app" --target-dir "$target_dir" 2>&1
}

assert_no_tcc_calls() {
  [[ ! -e "$MACKVM_TEST_TCC_LOG" ]] || fail "installer called tccutil: $(<"$MACKVM_TEST_TCC_LOG")"
}

# Fresh local ad-hoc installs stay supported.
source_app="$test_root/fresh-source/MacKVM.app"
target_dir="$test_root/fresh-target"
mkdir -p "$target_dir"
create_app "$source_app" local-build-1 "not set" "adhoc requirement"
output="$(run_installer)" || fail "fresh ad-hoc install failed: $output"
[[ "$(<"$target_dir/MacKVM.app/Contents/.test-version")" == local-build-1 ]] || fail "fresh ad-hoc app was not installed"
assert_no_tcc_calls

# Local ad-hoc builds can also replace an existing local ad-hoc install.
source_app="$test_root/adhoc-upgrade-source/MacKVM.app"
target_dir="$test_root/adhoc-upgrade-target"
mkdir -p "$target_dir"
create_app "$target_dir/MacKVM.app" local-build-1 "not set" "adhoc old requirement"
create_app "$source_app" local-build-2 "not set" "adhoc new requirement"
output="$(run_installer)" || fail "local ad-hoc upgrade failed: $output"
[[ "$(<"$target_dir/MacKVM.app/Contents/.test-version")" == local-build-2 ]] || fail "local ad-hoc upgrade did not replace the old app"
assert_no_tcc_calls

# An upgrade with the same Team ID and designated requirement is accepted.
source_app="$test_root/same-identity-source/MacKVM.app"
target_dir="$test_root/same-identity-target"
mkdir -p "$target_dir"
create_app "$target_dir/MacKVM.app" release-old TEAM12345 'identifier "app.mackvm.MacKVM" and anchor apple generic and certificate leaf[subject.OU] = "TEAM12345"'
create_app "$source_app" release-new TEAM12345 'identifier "app.mackvm.MacKVM" and anchor apple generic and certificate leaf[subject.OU] = "TEAM12345"'
output="$(run_installer)" || fail "same-identity upgrade failed: $output"
[[ "$(<"$target_dir/MacKVM.app/Contents/.test-version")" == release-new ]] || fail "same-identity upgrade did not replace the old app"
assert_no_tcc_calls

assert_rejected_upgrade() {
  local label="$1"
  local incoming_team="$2"
  local incoming_requirement="$3"
  local expected_message="$4"
  source_app="$test_root/$label-source/MacKVM.app"
  target_dir="$test_root/$label-target"
  mkdir -p "$target_dir"
  create_app "$target_dir/MacKVM.app" installed-old TEAM12345 'identifier "app.mackvm.MacKVM" and anchor apple generic and certificate leaf[subject.OU] = "TEAM12345"'
  create_app "$source_app" incoming "$incoming_team" "$incoming_requirement"
  if output="$(run_installer)"; then
    fail "$label upgrade unexpectedly succeeded"
  fi
  assert_contains "$output" "$expected_message"
  [[ "$(<"$target_dir/MacKVM.app/Contents/.test-version")" == installed-old ]] || fail "$label rejection changed the installed app"
  assert_no_tcc_calls
}

assert_rejected_upgrade \
  different-team \
  TEAM99999 \
  'identifier "app.mackvm.MacKVM" and anchor apple generic and certificate leaf[subject.OU] = "TEAM99999"' \
  'install a build signed for the same Team ID'
assert_rejected_upgrade \
  ad-hoc-incoming \
  'not set' \
  'adhoc requirement' \
  'install a build signed for the same Team ID'
assert_rejected_upgrade \
  different-requirement \
  TEAM12345 \
  'identifier "app.mackvm.MacKVM" and anchor apple generic and certificate leaf[subject.OU] = "OTHERTEAM"' \
  'different macOS code-signing requirement'

# A process query failure must preserve the installed app just like a failed
# signing-identity comparison.
source_app="$test_root/pgrep-error-source/MacKVM.app"
target_dir="$test_root/pgrep-error-target"
mkdir -p "$target_dir"
create_app "$target_dir/MacKVM.app" installed-old "not set" 'adhoc old'
create_app "$source_app" incoming "not set" 'adhoc new'
if output="$(MACKVM_TEST_PGREP_STATUS=3 run_installer)"; then
  fail "installer continued after pgrep returned an error"
fi
assert_contains "$output" 'pgrep exit 3'
[[ "$(<"$target_dir/MacKVM.app/Contents/.test-version")" == installed-old ]] || fail "pgrep failure changed the installed app"
assert_no_tcc_calls

echo "Installer identity and fail-closed process-query tests passed."
