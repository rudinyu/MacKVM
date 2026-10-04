#!/usr/bin/env bash
set -euo pipefail

app_name="MacKVM.app"
app_process_name="MacKVM"
expected_bundle_identifier="app.mackvm.MacKVM"
identity_defaults_domain="app.mackvm.device-identity"
identity_keychain_service="app.mackvm.device-identity"
identity_keychain_account="p256-signing-key"
target_dir="/Applications"
dry_run=false
purge=false
assume_yes=false
remove_firewall_rule=false

usage() {
  cat >&2 <<'EOF'
Usage: scripts/uninstall-app.sh [--target-dir PATH] [--dry-run]
       scripts/uninstall-app.sh --purge [--yes] [--dry-run]
       scripts/uninstall-app.sh --purge --remove-firewall-rule [--yes] [--dry-run]

Without --purge, removes only a validated MacKVM.app from /Applications (or
--target-dir). The release DMG includes this script as "Uninstall MacKVM.command".

--purge removes the app plus MacKVM's two user preference domains, its exact
device-identity Keychain item, and supported TCC permissions for this user.
It requires typing DELETE in an interactive terminal, or --yes when noninteractive.
--dry-run lists the scoped actions without changing files or settings.
--remove-firewall-rule additionally removes the rule for the exact validated
installed app path; it may request administrator authorization for that command.

Local Network, Notifications, the SMAppService login item, the Apple firewall
rule (unless selected above), and third-party Little Snitch rules may need manual
attention. User-exported logs and unified system logs are kept.
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

usage_error() {
  usage
  exit 2
}

is_path_within() {
  local candidate="$1"
  local parent="$2"
  [[ "$candidate" == "$parent" || "$candidate" == "$parent/"* ]]
}

path_has_symlink_component() {
  local path="$1"
  local component
  local current="/"
  local -a components=()

  IFS='/' read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="${current%/}/$component"
    [[ ! -L "$current" ]] || return 0
    [[ -e "$current" ]] || break
  done
  return 1
}

reject_unsafe_path_syntax() {
  local path="$1"
  [[ "$path" == /* ]] || die "Path must be absolute: $path"
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || die "Path contains a newline."
  case "$path" in
    */../*|*/..|*/./*|*/.)
      die "Path must not contain . or .. components: $path"
      ;;
  esac
}

project_root=""
detect_project_root() {
  local script_dir candidate
  script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || return 0
  if command -v git >/dev/null 2>&1; then
    candidate="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$candidate" && -d "$candidate" ]]; then
      project_root="$(cd -P "$candidate" 2>/dev/null && pwd -P)" || project_root=""
    fi
  fi
}

target_dir_exists=false
resolve_target_directory() {
  reject_unsafe_path_syntax "$target_dir"
  [[ "$target_dir" != "/" ]] || die "Refusing to use the filesystem root as an uninstall target."

  if [[ -L "$target_dir" ]] || path_has_symlink_component "$target_dir"; then
    die "Refusing a target directory path with a symlink component: $target_dir"
  fi

  if [[ -d "$target_dir" ]]; then
    target_dir="$(CDPATH= cd -P -- "$target_dir" && pwd -P)"
    target_dir_exists=true
  elif [[ -e "$target_dir" ]]; then
    die "Target path is not a directory: $target_dir"
  fi

  [[ "$target_dir" != "/" ]] || die "Refusing to use the filesystem root as an uninstall target."
  target_app="$target_dir/$app_name"

  if [[ -n "$project_root" ]] && is_path_within "$target_app" "$project_root"; then
    die "Refusing to remove an app path inside the project/workspace: $target_app"
  fi
}

current_uid=""
home_dir=""
preferences_dir=""
cache_path=""
saved_state_path=""
current_user_home() {
  local account_home
  account_home="$(dscacheutil -q user -a uid "$(id -u)" | awk -F ': ' '$1 == "dir" { print $2; exit }')" || return 1
  [[ -n "$account_home" ]] || return 1
  printf '%s\n' "$account_home"
}

validate_current_user_home() {
  current_uid="$(id -u)"
  [[ "$current_uid" != "0" ]] || die "Run this script as the logged-in user, not as root or through sudo."

  local requested_home home_uid path
  requested_home="$(current_user_home 2>/dev/null || true)"
  [[ -n "$requested_home" ]] || die "Could not resolve the current user's account home directory; refusing to purge user data."
  reject_unsafe_path_syntax "$requested_home"
  [[ "$requested_home" != "/" ]] || die "Refusing to use the filesystem root as the current user's home."
  if path_has_symlink_component "$requested_home"; then
    die "Refusing a HOME path with a symlink component: $requested_home"
  fi
  [[ -d "$requested_home" ]] || die "The current user's HOME is not a directory: $requested_home"

  home_dir="$(CDPATH= cd -P -- "$requested_home" && pwd -P)"
  [[ "$home_dir" != "/" ]] || die "Refusing to use the filesystem root as the current user's home."
  home_uid="$(stat -f '%u' "$home_dir" 2>/dev/null || true)"
  [[ "$home_uid" == "$current_uid" ]] || die "HOME is not owned by the current user; refusing to purge: $home_dir"
  if [[ -n "$project_root" ]] && is_path_within "$home_dir" "$project_root"; then
    die "Refusing to purge user data from a HOME inside the project/workspace: $home_dir"
  fi

  # These are the only preference domains used by MacKVM. Validate each
  # ancestor and final plist before any destructive action, without traversing
  # or removing a redirected Library/Preferences path.
  preferences_dir="$home_dir/Library/Preferences"
  local library_dir cache_dir saved_state_dir domain plist_path
  library_dir="$home_dir/Library"
  cache_dir="$home_dir/Library/Caches"
  saved_state_dir="$home_dir/Library/Saved Application State"
  for path in "$library_dir" "$preferences_dir" "$cache_dir" "$saved_state_dir"; do
    [[ ! -L "$path" ]] || die "Refusing a symlink in MacKVM's user-data path: $path"
    if [[ -e "$path" && ! -d "$path" ]]; then
      die "Unexpected non-directory in MacKVM's user-data path: $path"
    fi
  done
  for domain in "$identity_defaults_domain" "$expected_bundle_identifier"; do
    plist_path="$preferences_dir/$domain.plist"
    [[ ! -L "$plist_path" ]] || die "Refusing a symlinked preference file: $plist_path"
    if [[ -e "$plist_path" && ! -f "$plist_path" ]]; then
      die "Unexpected non-file at MacKVM preference path: $plist_path"
    fi
  done
  cache_path="$cache_dir/$expected_bundle_identifier"
  saved_state_path="$saved_state_dir/$expected_bundle_identifier.savedState"
  for path in "$cache_path" "$saved_state_path"; do
    [[ ! -L "$path" ]] || die "Refusing a symlinked MacKVM user-data directory: $path"
    if [[ -e "$path" && ! -d "$path" ]]; then
      die "Unexpected non-directory at MacKVM user-data path: $path"
    fi
  done
}

target_app=""
app_present=false
bundle_identifier=""
validate_target_app() {
  if [[ ! -e "$target_app" && ! -L "$target_app" ]]; then
    app_present=false
    return 0
  fi
  [[ ! -L "$target_app" ]] || die "Refusing to remove a symlink at $target_app"
  [[ -d "$target_app" ]] || die "Refusing to remove a non-directory at $target_app"
  [[ ! -L "$target_app/Contents" ]] || die "Refusing an app with a symlinked Contents directory: $target_app"
  [[ ! -L "$target_app/Contents/Info.plist" ]] || die "Refusing an app with a symlinked Info.plist: $target_app"
  [[ -f "$target_app/Contents/Info.plist" ]] || die "Refusing to remove an app without a valid Info.plist: $target_app"

  bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - \
    "$target_app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$bundle_identifier" == "$expected_bundle_identifier" ]] || {
    die "Refusing to remove unexpected bundle identifier: ${bundle_identifier:-<missing>}"
  }
  app_present=true
}

check_app_stopped() {
  local status
  local target_binary="$target_app/Contents/MacOS/MacKVM"
  local process_pattern="$target_binary"

  if [[ "$purge" == true ]]; then
    process_pattern="$app_process_name"
    command -v pgrep >/dev/null 2>&1 || die "Cannot verify that MacKVM is stopped because pgrep is unavailable."
    if pgrep -x "$process_pattern" >/dev/null 2>&1; then
      die "MacKVM is running; quit every MacKVM process before purging."
    else
      status=$?
    fi
  elif [[ "$app_present" == true && -x "$target_binary" ]]; then
    command -v pgrep >/dev/null 2>&1 || die "Cannot verify that MacKVM is stopped because pgrep is unavailable."
    if pgrep -f "$process_pattern" >/dev/null 2>&1; then
      die "MacKVM is running from $target_app; quit it before uninstalling."
    else
      status=$?
    fi
  else
    return 0
  fi
  [[ "$status" -eq 1 ]] || die "Could not verify whether MacKVM is stopped (pgrep exit $status)."
}

tree_is_user_removable() {
  local path="$1"
  local directory
  [[ -w "$(dirname "$path")" && -x "$(dirname "$path")" ]] || return 1
  while IFS= read -r -d '' directory; do
    [[ -w "$directory" && -x "$directory" ]] || return 1
  done < <(find "$path" -type d -print0)
}

remove_validated_app() {
  if [[ "$app_present" != true ]]; then
    echo "MacKVM.app is not installed at $target_app"
    return 0
  fi

  if tree_is_user_removable "$target_app"; then
    if rm -rf -- "$target_app"; then
      echo "Removed MacKVM from $target_app"
    else
      echo "Could not remove MacKVM from $target_app" >&2
      return 1
    fi
  elif sudo rm -rf -- "$target_app"; then
    echo "Removed MacKVM from $target_app (administrator authorization was used for this bundle only)"
  else
    echo "Could not remove MacKVM from $target_app" >&2
    return 1
  fi
}

purge_failed=false
record_failure() {
  echo "$*" >&2
  purge_failed=true
}

remove_firewall_rule_for_validated_app() {
  if sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove "$target_app"; then
    echo "Removed the application firewall rule for $target_app"
    return 0
  else
    echo "Could not remove the application firewall rule for $target_app; app and user data were preserved." >&2
    return 1
  fi
}

remove_keychain_item() {
  local output status
  if ! command -v security >/dev/null 2>&1; then
    record_failure "Could not check the MacKVM Keychain item because security is unavailable."
    return 1
  fi

  if output="$(security find-generic-password \
    -s "$identity_keychain_service" -a "$identity_keychain_account" 2>&1)"; then
    if security delete-generic-password \
      -s "$identity_keychain_service" -a "$identity_keychain_account" >/dev/null 2>&1; then
      echo "Removed the MacKVM device-identity Keychain item."
      return 0
    else
      status=$?
      record_failure "Could not delete the MacKVM device-identity Keychain item (security exit $status). Its identity preferences will be preserved."
      return 1
    fi
  else
    status=$?
  fi

  # `security` reports errSecItemNotFound using this stable status text. Do
  # not treat authorization, locked-keychain, or other failures as absence.
  case "$output" in
    *"could not be found in the keychain"*|*"item not found"*|*"errSecItemNotFound"*)
      echo "No matching MacKVM device-identity Keychain item was found."
      return 0
      ;;
    *)
      record_failure "Could not check the MacKVM device-identity Keychain item (security exit $status). Its identity preferences will be preserved."
      return 1
      ;;
  esac
}

inspect_preference_domain() {
  local domain="$1"
  local plist_path="$preferences_dir/$domain.plist"
  local output status

  if output="$(defaults read "$domain" 2>&1)"; then
    echo "present"
    return 0
  else
    status=$?
    case "$output" in
      *"does not exist"*|*"domain/default pair"*"does not exist"*)
        if [[ -e "$plist_path" ]]; then
          return 1
        else
          echo "absent"
          return 0
        fi
        ;;
      *)
        return 1
        ;;
    esac
  fi
}

remove_preference_domain() {
  local domain="$1"
  local state="$2"
  local status

  if [[ "$state" == absent ]]; then
    echo "No saved preferences found for $domain."
    return 0
  fi

  if defaults delete "$domain" >/dev/null 2>&1; then
    echo "Removed saved preferences for $domain."
  else
    status=$?
    record_failure "Could not remove saved preferences for $domain (defaults exit $status)."
  fi
}

remove_scoped_directory() {
  local path="$1"
  local label="$2"
  if [[ ! -e "$path" ]]; then
    echo "No MacKVM $label found."
  elif rm -rf -- "$path"; then
    echo "Removed MacKVM $label at $path"
  else
    record_failure "Could not remove MacKVM $label at $path."
  fi
}

confirm_purge() {
  [[ "$purge" == true && "$dry_run" == false && "$assume_yes" == false ]] || return 0
  if [[ -t 0 && -r /dev/tty && -w /dev/tty ]]; then
    printf 'This permanently removes MacKVM preferences and its device identity. Type DELETE to continue: ' > /dev/tty
    local response
    IFS= read -r response < /dev/tty || response=""
    [[ "$response" == "DELETE" ]] || die "Confirmation did not match DELETE; nothing was changed."
  else
    die "Noninteractive purge requires --yes. No changes were made."
  fi
}

main() {
local identity_preferences_state standard_preferences_state
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)
      [[ $# -ge 2 && -n "$2" ]] || usage_error
      target_dir="$2"
      shift 2
      ;;
    --target-dir=*)
      target_dir="${1#--target-dir=}"
      [[ -n "$target_dir" ]] || usage_error
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --purge)
      purge=true
      shift
      ;;
    --yes)
      assume_yes=true
      shift
      ;;
    --remove-firewall-rule)
      remove_firewall_rule=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error
      ;;
  esac
done

if [[ "$assume_yes" == true && "$purge" != true ]]; then
  die "--yes is only valid together with --purge."
fi
if [[ "$remove_firewall_rule" == true && "$purge" != true ]]; then
  die "--remove-firewall-rule requires --purge."
fi

detect_project_root
[[ "$(id -u)" != "0" ]] || die "Run this script as the logged-in user, not as root or through sudo."
resolve_target_directory
if [[ "$purge" == true ]]; then
  validate_current_user_home
fi
validate_target_app
check_app_stopped

if [[ "$remove_firewall_rule" == true && "$app_present" != true ]]; then
  die "Cannot remove a firewall rule without a present, validated MacKVM.app at $target_app."
fi

echo "Target: $target_app"
if [[ "$app_present" == true ]]; then
  echo "Bundle identifier validated: $bundle_identifier"
else
  echo "MacKVM.app is absent at the target; scoped user-data cleanup can still proceed."
fi

if [[ "$purge" != true ]]; then
  if [[ "$dry_run" == true ]]; then
    if [[ "$app_present" == true ]]; then
      echo "Dry run: would remove only the validated app bundle; no files were changed."
    else
      echo "Dry run: no app bundle is present; no files were changed."
    fi
    exit 0
  fi

  if remove_validated_app; then
    echo "User preferences, paired device data, private keys, and macOS privacy permissions were preserved."
    echo "If MacKVM was enabled as a login item, remove it from System Settings > General > Login Items."
  else
    exit 1
  fi
  exit 0
fi

if [[ "$dry_run" == true ]]; then
  [[ "$app_present" != true ]] || echo "Would remove app bundle: $target_app"
  echo "Would remove preference domain: $identity_defaults_domain"
  echo "Would remove preference domain: $expected_bundle_identifier"
  echo "Would remove MacKVM cache if present: $cache_path"
  echo "Would remove MacKVM saved application state if present: $saved_state_path"
  echo "Would remove Keychain generic-password: service=$identity_keychain_service account=$identity_keychain_account"
  echo "Would run for the current user: tccutil reset All $expected_bundle_identifier"
  if [[ "$remove_firewall_rule" == true ]]; then
    echo "Would remove only the firewall rule for validated app path: $target_app"
  fi
  echo "Manual follow-up may remain: Local Network, Notifications, the SMAppService login item, the Apple firewall rule if not selected, and third-party Little Snitch rules."
  echo "Dry run: no files or settings were changed."
  exit 0
fi

confirm_purge
check_app_stopped

identity_preferences_state="$(inspect_preference_domain "$identity_defaults_domain")" || die "Could not safely inspect $identity_defaults_domain preferences; no settings were changed."
standard_preferences_state="$(inspect_preference_domain "$expected_bundle_identifier")" || die "Could not safely inspect $expected_bundle_identifier preferences; no settings were changed."

if [[ "$remove_firewall_rule" == true ]]; then
  if ! remove_firewall_rule_for_validated_app; then
    exit 1
  fi
fi

if command -v tccutil >/dev/null 2>&1; then
  if tccutil reset All "$expected_bundle_identifier"; then
    echo "Reset supported TCC permissions for $expected_bundle_identifier in the current user account."
  else
    status=$?
    record_failure "Could not reset supported TCC permissions for $expected_bundle_identifier (tccutil exit $status)."
  fi
else
  record_failure "Could not reset supported TCC permissions because tccutil is unavailable."
fi

if [[ "$app_present" == true ]]; then
  if ! remove_validated_app; then
    purge_failed=true
  fi
else
  echo "No app bundle to remove at $target_app; continuing with scoped user-data cleanup."
fi

identity_item_removed=true
if ! remove_keychain_item; then
  identity_item_removed=false
fi

if [[ "$identity_item_removed" == true ]]; then
  remove_preference_domain "$identity_defaults_domain" "$identity_preferences_state"
else
  echo "Kept identity preferences because the matching Keychain item could not be safely removed."
fi
remove_preference_domain "$expected_bundle_identifier" "$standard_preferences_state"
remove_scoped_directory "$cache_path" "cache"
remove_scoped_directory "$saved_state_path" "saved application state"

echo "Manual follow-up in System Settings may still be needed:"
echo "  - Privacy & Security > Local Network: turn off MacKVM; macOS cannot reset this permission to undetermined."
echo "  - Notifications > MacKVM: review or remove its notification settings if listed."
echo "  - General > Login Items: remove MacKVM if it remains registered; its SMAppService entry is not changed by this script."
if [[ "$remove_firewall_rule" != true ]]; then
  echo "  - Firewall > Options: remove the MacKVM rule if present; third-party Little Snitch rules are not changed."
else
  echo "  - Third-party Little Snitch rules are not changed by this script."
fi
echo "User-exported logs and unified system logs were kept."

if [[ "$purge_failed" == true ]]; then
  echo "MacKVM purge was incomplete; review the errors above. Some independent items may already have been removed." >&2
  exit 1
fi

echo "Automated MacKVM cleanup finished; complete any applicable manual System Settings steps above."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
