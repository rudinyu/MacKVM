#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
uninstaller="$project_root/scripts/uninstall-app.sh"
test_root="$(mktemp -d /private/tmp/mackvm-uninstaller-test.XXXXXX)"
cleanup() {
  /bin/rm -rf -- "$test_root"
}
trap cleanup EXIT

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

tool="${0##*/}"
printf '%s\t%s\n' "$tool" "$*" >> "$MACKVM_TEST_LOG"

case "$tool" in
  plutil)
    printf '%s\n' "${MACKVM_TEST_BUNDLE_ID:-app.mackvm.MacKVM}"
    ;;
  pgrep)
    [[ "${MACKVM_TEST_RUNNING:-false}" == true ]] && exit 0
    exit 1
    ;;
  security)
    case "${1:-}" in
      find-generic-password)
        case "${MACKVM_TEST_KEYCHAIN_MODE:-present}" in
          present) exit 0 ;;
          missing)
            echo "security: The specified item could not be found in the keychain. (errSecItemNotFound)" >&2
            exit 44
            ;;
          denied)
            echo "security: User interaction is not allowed." >&2
            exit 44
            ;;
          *)
            echo "security: unexpected test mode" >&2
            exit 50
            ;;
        esac
        ;;
      delete-generic-password)
        [[ "${MACKVM_TEST_KEYCHAIN_MODE:-present}" == present ]] || exit 44
        : > "$MACKVM_TEST_KEYCHAIN_DELETED"
        ;;
      *)
        echo "unexpected security subcommand" >&2
        exit 50
        ;;
    esac
    ;;
  defaults)
    [[ $# -eq 2 ]] || exit 50
    case "$2" in
      app.mackvm.device-identity)
        plist="$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
        ;;
      app.mackvm.MacKVM)
        plist="$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.MacKVM.plist"
        ;;
      *)
        exit 50
        ;;
    esac
    if [[ "$1" == read ]]; then
      if [[ "${MACKVM_TEST_DEFAULTS_DENIED:-false}" == true ]]; then
        echo "defaults: operation not permitted" >&2
        exit 13
      fi
      if [[ "${MACKVM_TEST_DEFAULTS_FORCE_PRESENT:-false}" == true ]]; then
        exit 0
      fi
      if [[ -f "$plist" ]]; then
        exit 0
      fi
      echo "The domain/default pair of $2 does not exist" >&2
      exit 1
    fi
    [[ "$1" == delete ]] || exit 50
    /bin/rm -f -- "$plist"
    ;;
  tccutil)
    [[ "${MACKVM_TEST_TCC_STATUS:-0}" == 0 ]] || exit "$MACKVM_TEST_TCC_STATUS"
    ;;
  sudo)
    printf '%s\n' "$*" > "$MACKVM_TEST_SUDO_ARGS"
    [[ "${MACKVM_TEST_SUDO_STATUS:-0}" == 0 ]] || exit "$MACKVM_TEST_SUDO_STATUS"
    ;;
  *)
    echo "unexpected mocked command: $tool" >&2
    exit 50
    ;;
esac
MOCK
chmod 755 "$fake_bin/mock-command"
for command_name in plutil pgrep security defaults tccutil sudo; do
  ln -s mock-command "$fake_bin/$command_name"
done
export PATH="$fake_bin:$PATH"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_exists() {
  [[ -e "$1" ]] || fail "expected path to exist: $1"
}

assert_absent() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "expected path to be absent: $1"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected output to contain: $2" ;;
  esac
}

assert_no_mutating_tool_calls() {
  local log_path="$1"
  if grep -Eq '^(defaults[[:space:]]delete|security[[:space:]]delete|tccutil[[:space:]]|sudo[[:space:]])' "$log_path"; then
    fail "dry-run or refused purge invoked a mutating command: $(<"$log_path")"
  fi
}

new_case() {
  case_root="$test_root/$1"
  fake_home="$case_root/home"
  target_dir="$case_root/apps"
  mkdir -p \
    "$fake_home/Library/Preferences" \
    "$fake_home/Library/Caches/app.mackvm.MacKVM" \
    "$fake_home/Library/Caches/com.example.Unrelated" \
    "$fake_home/Library/Saved Application State/app.mackvm.MacKVM.savedState" \
    "$fake_home/Library/Saved Application State/com.example.Unrelated.savedState" \
    "$target_dir"
  export MACKVM_TEST_HOME="$fake_home"
  export MACKVM_TEST_LOG="$case_root/tool-calls.log"
  export MACKVM_TEST_KEYCHAIN_DELETED="$case_root/keychain-deleted"
  export MACKVM_TEST_SUDO_ARGS="$case_root/sudo-args"
  export MACKVM_TEST_BUNDLE_ID="app.mackvm.MacKVM"
  export MACKVM_TEST_KEYCHAIN_MODE=present
  export MACKVM_TEST_RUNNING=false
  export MACKVM_TEST_TCC_STATUS=0
  export MACKVM_TEST_DEFAULTS_DENIED=false
  export MACKVM_TEST_DEFAULTS_FORCE_PRESENT=false
  : > "$MACKVM_TEST_LOG"
  create_app "$target_dir"
  : > "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
  : > "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.MacKVM.plist"
}

run_uninstaller() (
  source "$uninstaller"
  current_user_home() {
    printf '%s\n' "$MACKVM_TEST_HOME"
  }
  main "$@"
)

run_uninstaller_reopened_after_confirmation() (
  source "$uninstaller"
  current_user_home() {
    printf '%s\n' "$MACKVM_TEST_HOME"
  }
  confirm_purge() {
    export MACKVM_TEST_RUNNING=true
  }
  main "$@"
)

create_app() {
  local apps_dir="$1"
  mkdir -p "$apps_dir/MacKVM.app/Contents/MacOS"
  : > "$apps_dir/MacKVM.app/Contents/Info.plist"
  : > "$apps_dir/MacKVM.app/Contents/MacOS/MacKVM"
  chmod 755 "$apps_dir/MacKVM.app/Contents/MacOS/MacKVM"
}

# Legacy mode still removes only the validated app bundle.
new_case legacy
output="$(run_uninstaller --target-dir "$target_dir")"
assert_absent "$target_dir/MacKVM.app"
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.MacKVM.plist"
assert_exists "$MACKVM_TEST_HOME/Library/Caches/app.mackvm.MacKVM"
assert_contains "$output" "User preferences, paired device data, private keys, and macOS privacy permissions were preserved."
if grep -Eq '^(defaults|security|tccutil|sudo)[[:space:]]' "$MACKVM_TEST_LOG"; then
  fail "legacy mode invoked purge-only commands"
fi

# A purge dry-run, including the optional firewall action, must enumerate but
# not execute any mutation and must not require confirmation.
new_case dry-run
output="$(run_uninstaller --purge --remove-firewall-rule --dry-run --target-dir "$target_dir")"
assert_contains "$output" "Would remove preference domain: app.mackvm.device-identity"
assert_contains "$output" "Would remove MacKVM cache if present: $MACKVM_TEST_HOME/Library/Caches/app.mackvm.MacKVM"
assert_contains "$output" "Would remove MacKVM saved application state if present: $MACKVM_TEST_HOME/Library/Saved Application State/app.mackvm.MacKVM.savedState"
assert_contains "$output" "Would remove Keychain generic-password: service=app.mackvm.device-identity account=p256-signing-key"
assert_contains "$output" "Would run for the current user: tccutil reset All app.mackvm.MacKVM"
assert_contains "$output" "Would remove only the firewall rule for validated app path: $target_dir/MacKVM.app"
assert_exists "$target_dir/MacKVM.app"
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.MacKVM.plist"
assert_no_mutating_tool_calls "$MACKVM_TEST_LOG"

# Noninteractive destructive purge refuses without --yes and leaves all data.
new_case confirmation
if output="$(run_uninstaller --purge --target-dir "$target_dir" 2>&1 </dev/null)"; then
  fail "noninteractive purge unexpectedly proceeded without --yes"
fi
assert_contains "$output" "Noninteractive purge requires --yes. No changes were made."
assert_exists "$target_dir/MacKVM.app"
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_no_mutating_tool_calls "$MACKVM_TEST_LOG"

# Successful purge uses exact, mocked user-scoped boundaries.
new_case purge
output="$(run_uninstaller --purge --yes --target-dir "$target_dir")"
assert_absent "$target_dir/MacKVM.app"
assert_absent "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_absent "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.MacKVM.plist"
assert_absent "$MACKVM_TEST_HOME/Library/Caches/app.mackvm.MacKVM"
assert_absent "$MACKVM_TEST_HOME/Library/Saved Application State/app.mackvm.MacKVM.savedState"
assert_exists "$MACKVM_TEST_HOME/Library/Caches/com.example.Unrelated"
assert_exists "$MACKVM_TEST_HOME/Library/Saved Application State/com.example.Unrelated.savedState"
assert_exists "$MACKVM_TEST_KEYCHAIN_DELETED"
assert_contains "$output" "Reset supported TCC permissions for app.mackvm.MacKVM in the current user account."
grep -q $'^security\tfind-generic-password -s app.mackvm.device-identity -a p256-signing-key$' "$MACKVM_TEST_LOG" || fail "Keychain lookup was not narrowly scoped"
grep -q $'^security\tdelete-generic-password -s app.mackvm.device-identity -a p256-signing-key$' "$MACKVM_TEST_LOG" || fail "Keychain deletion was not narrowly scoped"
grep -q $'^tccutil\treset All app.mackvm.MacKVM$' "$MACKVM_TEST_LOG" || fail "TCC reset was not scoped to the MacKVM bundle"
if grep -Eq '^sudo[[:space:]]' "$MACKVM_TEST_LOG"; then
  fail "normal purge used sudo"
fi
assert_contains "$output" "Local Network"
assert_contains "$output" "SMAppService"
assert_contains "$output" "Little Snitch"

# Missing app bundle still permits cleanup of scoped leftovers.
new_case missing-app
/bin/rm -rf -- "$target_dir/MacKVM.app"
output="$(run_uninstaller --purge --yes --target-dir "$target_dir")"
assert_absent "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_absent "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.MacKVM.plist"
assert_contains "$output" "continuing with scoped user-data cleanup"

# A missing exact Keychain item is benign; an access failure is not.
new_case missing-key
export MACKVM_TEST_KEYCHAIN_MODE=missing
output="$(run_uninstaller --purge --yes --target-dir "$target_dir")"
assert_absent "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_contains "$output" "No matching MacKVM device-identity Keychain item was found."
if grep -q $'^security\tdelete-generic-password' "$MACKVM_TEST_LOG"; then
  fail "uninstaller tried to delete a Keychain item that was absent"
fi

# A CFPreferences domain may still be cached when its plist file is absent.
new_case cached-domain
/bin/rm -f -- "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
export MACKVM_TEST_DEFAULTS_FORCE_PRESENT=true
output="$(run_uninstaller --purge --yes --target-dir "$target_dir")"
grep -q $'^defaults\tdelete app.mackvm.device-identity$' "$MACKVM_TEST_LOG" || fail "cached identity domain was skipped because its plist was absent"

new_case denied-defaults
export MACKVM_TEST_DEFAULTS_DENIED=true
if output="$(run_uninstaller --purge --yes --target-dir "$target_dir" 2>&1)"; then
  fail "defaults read denial proceeded with a purge"
fi
assert_contains "$output" "Could not safely inspect app.mackvm.device-identity preferences"
assert_exists "$target_dir/MacKVM.app"
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_no_mutating_tool_calls "$MACKVM_TEST_LOG"

new_case denied-key
export MACKVM_TEST_KEYCHAIN_MODE=denied
if output="$(run_uninstaller --purge --yes --target-dir "$target_dir" 2>&1)"; then
  fail "Keychain denial was reported as a complete purge"
fi
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_absent "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.MacKVM.plist"
assert_contains "$output" "Its identity preferences will be preserved."
assert_contains "$output" "MacKVM purge was incomplete"

# A running app blocks purge even if the target bundle is already absent.
new_case running
/bin/rm -rf -- "$target_dir/MacKVM.app"
export MACKVM_TEST_RUNNING=true
if output="$(run_uninstaller --purge --yes --target-dir "$target_dir" 2>&1)"; then
  fail "purge proceeded while MacKVM was running"
fi
assert_contains "$output" "quit every MacKVM process before purging"
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_no_mutating_tool_calls "$MACKVM_TEST_LOG"

# A second process check after confirmation closes the window where a user
# could reopen MacKVM while the purge prompt is waiting for input.
new_case reopened
if output="$(run_uninstaller_reopened_after_confirmation --purge --yes --target-dir "$target_dir" 2>&1)"; then
  fail "purge proceeded after MacKVM reopened during confirmation"
fi
assert_contains "$output" "quit every MacKVM process before purging"
assert_exists "$target_dir/MacKVM.app"
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_no_mutating_tool_calls "$MACKVM_TEST_LOG"

# Reject bad bundle identity and symlinked preference ancestors before writes.
new_case wrong-bundle
export MACKVM_TEST_BUNDLE_ID=other.vendor.App
if output="$(run_uninstaller --purge --yes --target-dir "$target_dir" 2>&1)"; then
  fail "unexpected bundle identity was accepted"
fi
assert_exists "$target_dir/MacKVM.app"
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_no_mutating_tool_calls "$MACKVM_TEST_LOG"

new_case symlink-preferences
outside="$case_root/outside"
mkdir -p "$outside/Preferences"
: > "$outside/Preferences/app.mackvm.MacKVM.plist"
/bin/rm -rf -- "$MACKVM_TEST_HOME/Library"
ln -s "$outside" "$MACKVM_TEST_HOME/Library"
if output="$(run_uninstaller --purge --yes --target-dir "$target_dir" 2>&1)"; then
  fail "symlinked preference ancestor was accepted"
fi
assert_exists "$target_dir/MacKVM.app"
assert_exists "$outside/Preferences/app.mackvm.MacKVM.plist"
assert_no_mutating_tool_calls "$MACKVM_TEST_LOG"

# The optional firewall action uses sudo only for socketfilterfw and the exact
# validated app path; a missing bundle cannot trigger a guessed-path removal.
new_case firewall
output="$(run_uninstaller --purge --yes --remove-firewall-rule --target-dir "$target_dir")"
[[ "$(<"$MACKVM_TEST_SUDO_ARGS")" == "/usr/libexec/ApplicationFirewall/socketfilterfw --remove $target_dir/MacKVM.app" ]] || fail "firewall removal command was not exact and app-scoped"
assert_absent "$target_dir/MacKVM.app"

new_case firewall-failure
export MACKVM_TEST_SUDO_STATUS=1
if output="$(run_uninstaller --purge --yes --remove-firewall-rule --target-dir "$target_dir" 2>&1)"; then
  fail "firewall removal failure was reported as a successful purge"
fi
assert_contains "$output" "app and user data were preserved"
assert_exists "$target_dir/MacKVM.app"
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.MacKVM.plist"
if grep -q $'^tccutil\t' "$MACKVM_TEST_LOG"; then
  fail "TCC reset ran after the explicitly requested firewall removal failed"
fi

new_case firewall-missing
/bin/rm -rf -- "$target_dir/MacKVM.app"
if output="$(run_uninstaller --purge --yes --remove-firewall-rule --target-dir "$target_dir" 2>&1)"; then
  fail "firewall removal accepted a missing, unvalidated app bundle"
fi
assert_exists "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
if grep -q $'^sudo\t' "$MACKVM_TEST_LOG"; then
  fail "firewall command ran without a validated bundle"
fi

# TCC failure is surfaced without claiming success, while independent scoped
# cleanup may still complete.
new_case tcc-failure
export MACKVM_TEST_TCC_STATUS=1
if output="$(run_uninstaller --purge --yes --target-dir "$target_dir" 2>&1)"; then
  fail "TCC failure was reported as a complete purge"
fi
assert_absent "$MACKVM_TEST_HOME/Library/Preferences/app.mackvm.device-identity.plist"
assert_contains "$output" "Could not reset supported TCC permissions"
assert_contains "$output" "MacKVM purge was incomplete"

echo "Uninstaller regression checks passed."
