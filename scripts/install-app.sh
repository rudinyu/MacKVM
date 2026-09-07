#!/usr/bin/env bash
set -euo pipefail

app_name="MacKVM.app"
expected_bundle_identifier="app.mackvm.MacKVM"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_app="$script_dir/$app_name"
target_dir="/Applications"
dry_run=false
launch_after_install=false

usage() {
  cat >&2 <<'EOF'
Usage: scripts/install-app.sh [--source PATH] [--target-dir PATH]
       [--launch] [--dry-run]

Installs a validated MacKVM.app into /Applications by default. The same
script is placed in the release DMG as "Install MacKVM.command" so it can be
double-clicked from Finder. Existing app data, pairing keys, and macOS
privacy permissions are not changed.
EOF
}

die() {
  echo "Install failed: $*" >&2
  exit 1
}

require_absolute_directory() {
  local path="$1"
  [[ "$path" == /* ]] || {
    echo "Target directory must be an absolute path: $path" >&2
    exit 2
  }
  [[ "$path" != "/" ]] || {
    echo "Refusing to use the filesystem root as an install target." >&2
    exit 2
  }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      source_app="$2"
      shift 2
      ;;
    --source=*)
      source_app="${1#--source=}"
      [[ -n "$source_app" ]] || { usage; exit 2; }
      shift
      ;;
    --target-dir)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      target_dir="$2"
      shift 2
      ;;
    --target-dir=*)
      target_dir="${1#--target-dir=}"
      [[ -n "$target_dir" ]] || { usage; exit 2; }
      shift
      ;;
    --launch)
      launch_after_install=true
      shift
      ;;
    --dry-run)
      dry_run=true
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

if [[ "$source_app" != /* ]]; then
  source_app="$(cd "$(dirname "$source_app")" && pwd)/$(basename "$source_app")"
fi
if [[ "$target_dir" != "/" ]]; then
  target_dir="${target_dir%/}"
fi
require_absolute_directory "$target_dir"
target_app="$target_dir/$app_name"

target_requires_privilege=false
privilege_anchor="$target_dir"
if [[ ! -d "$privilege_anchor" ]]; then
  privilege_anchor="$(dirname "$privilege_anchor")"
fi
if [[ ! -w "$privilege_anchor" || ! -x "$privilege_anchor" ]]; then
  target_requires_privilege=true
fi

[[ -d "$source_app" ]] || die "app bundle not found: $source_app"
[[ -f "$source_app/Contents/Info.plist" ]] || die "Info.plist not found in $source_app"
[[ -x "$source_app/Contents/MacOS/MacKVM" ]] || die "MacKVM executable not found in $source_app"

bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - \
  "$source_app/Contents/Info.plist" 2>/dev/null)" || {
  die "could not read the app bundle identifier"
}
[[ "$bundle_identifier" == "$expected_bundle_identifier" ]] || {
  die "unexpected bundle identifier: $bundle_identifier"
}

codesign --verify --deep --strict "$source_app" >/dev/null 2>&1 || {
  die "the source app has an invalid code signature: $source_app"
}

if [[ -e "$target_app" || -L "$target_app" ]]; then
  [[ ! -L "$target_app" ]] || die "refusing to replace a symlink at $target_app"
  [[ -f "$target_app/Contents/Info.plist" ]] || {
    die "existing target is not a MacKVM app bundle: $target_app"
  }
  existing_bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - \
    "$target_app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$existing_bundle_identifier" == "$expected_bundle_identifier" ]] || {
    die "existing target has an unexpected bundle identifier: $existing_bundle_identifier"
  }
fi

target_binary="$target_app/Contents/MacOS/MacKVM"
if [[ -x "$target_binary" ]] && pgrep -f "$target_binary" >/dev/null 2>&1; then
  die "MacKVM is running; quit it before installing the new app"
fi

echo "Source: $source_app"
echo "Target: $target_app"
tree_is_user_removable() {
  local path="$1"
  local parent_dir="$(dirname "$path")"
  [[ -w "$parent_dir" && -x "$parent_dir" ]] || return 1
  [[ -d "$path" ]] || return 0

  while IFS= read -r -d '' directory; do
    [[ -w "$directory" && -x "$directory" ]] || return 1
  done < <(find "$path" -type d -print0)
}

remove_tree() {
  local path="$1"
  if tree_is_user_removable "$path"; then
    rm -rf -- "$path"
  else
    sudo rm -rf -- "$path"
  fi
}

run_target() {
  if [[ "$target_requires_privilege" == true ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

if [[ "$dry_run" == true ]]; then
  echo "Dry run: no files were changed."
  if [[ "$launch_after_install" == true ]]; then
    echo "Dry run: would launch $target_app after installation."
  fi
  exit 0
fi

if [[ ! -d "$target_dir" ]]; then
  run_target mkdir -p "$target_dir"
fi

temporary_dir=""
cleanup() {
  if [[ -n "$temporary_dir" && -d "$temporary_dir" ]]; then
    remove_tree "$temporary_dir"
  fi
}
trap cleanup EXIT

temporary_dir="$(run_target mktemp -d "$target_dir/.MacKVM-install.XXXXXX")"
run_target ditto "$source_app" "$temporary_dir/$app_name"
run_target codesign --verify --deep --strict "$temporary_dir/$app_name" >/dev/null 2>&1 || {
  die "the copied app failed code-signature validation"
}

backup_app=""
if [[ -e "$target_app" ]]; then
  backup_app="$target_dir/.MacKVM-previous.$$.app"
  run_target mv "$target_app" "$backup_app"
fi

if ! run_target mv "$temporary_dir/$app_name" "$target_app"; then
  if [[ -n "$backup_app" && -e "$backup_app" && ! -e "$target_app" ]]; then
    run_target mv "$backup_app" "$target_app" || true
  fi
  die "could not move the validated app into $target_app"
fi

if [[ -n "$backup_app" && -e "$backup_app" ]]; then
  remove_tree "$backup_app"
fi

echo "Installed MacKVM at $target_app"
echo "Pairing data, private keys, and macOS privacy permissions were preserved."
if [[ "$launch_after_install" == true ]]; then
  open "$target_app"
fi
