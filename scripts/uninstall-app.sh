#!/usr/bin/env bash
set -euo pipefail

app_name="MacKVM.app"
expected_bundle_identifier="app.mackvm.MacKVM"
target_dir="/Applications"
dry_run=false

usage() {
  cat >&2 <<'EOF'
Usage: scripts/uninstall-app.sh [--target-dir PATH] [--dry-run]

Removes MacKVM.app from /Applications by default. The same script is placed
in the release DMG as "Uninstall MacKVM.command". User preferences, paired
device data, private keys, and macOS privacy permissions are intentionally
left untouched.
EOF
}

require_absolute_directory() {
  local path="$1"
  [[ "$path" == /* ]] || {
    echo "Target directory must be an absolute path: $path" >&2
    exit 2
  }
  [[ "$path" != "/" ]] || {
    echo "Refusing to use the filesystem root as an uninstall target." >&2
    exit 2
  }
}

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

while [[ $# -gt 0 ]]; do
  case "$1" in
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

if [[ "$target_dir" != "/" ]]; then
  target_dir="${target_dir%/}"
fi
require_absolute_directory "$target_dir"
target_app="$target_dir/$app_name"
target_binary="$target_app/Contents/MacOS/MacKVM"

if [[ ! -e "$target_app" && ! -L "$target_app" ]]; then
  echo "MacKVM is not installed at $target_app"
  exit 0
fi

[[ ! -L "$target_app" ]] || {
  echo "Refusing to remove a symlink at $target_app" >&2
  exit 1
}
[[ -f "$target_app/Contents/Info.plist" ]] || {
  echo "Refusing to remove an app without a valid Info.plist: $target_app" >&2
  exit 1
}

bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - \
  "$target_app/Contents/Info.plist" 2>/dev/null || true)"
[[ "$bundle_identifier" == "$expected_bundle_identifier" ]] || {
  echo "Refusing to remove unexpected bundle identifier: $bundle_identifier" >&2
  exit 1
}

if [[ -x "$target_binary" ]] && pgrep -f "$target_binary" >/dev/null 2>&1; then
  echo "MacKVM is running; quit it before uninstalling" >&2
  exit 1
fi

echo "Target: $target_app"
if [[ "$dry_run" == true ]]; then
  echo "Dry run: no files were changed."
  exit 0
fi

remove_tree "$target_app"
echo "Removed MacKVM from $target_app"
echo "User preferences, paired device data, private keys, and macOS privacy permissions were preserved."
echo "If Launch MacKVM at Login was enabled, remove MacKVM from System Settings > General > Login Items."
