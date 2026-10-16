#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_app="$project_root/dist/arm64/MacKVM.app"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/mackvm-installer.XXXXXX")"
test_root="$(CDPATH= cd -P -- "$test_root" && pwd -P)"
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

target_dir="$test_root/Applications"
target_app="$target_dir/MacKVM.app"
target_binary="$target_app/Contents/MacOS/MacKVM"

# This fixture only answers the exact full-path query made by the uninstaller
# for this copied bundle. Any other query fails so process-state coverage
# cannot silently drift into a host process lookup. It also covers the
# installer invocation so a future lifecycle change cannot reach host pgrep.
fake_bin="$test_root/pgrep-fixture"
pgrep_log="$test_root/pgrep-call.log"
unexpected_pgrep_log="$test_root/pgrep-unexpected.log"
mkdir -p "$fake_bin"
cat > "$fake_bin/pgrep" <<'PGREP'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'argc=%s' "$#"
  for argument in "$@"; do
    printf '\t%s' "$argument"
  done
  printf '\n'
} >> "$MACKVM_PGREP_LOG"

if [[ "$#" -ne 2 || "$1" != "-f" || "$2" != "$MACKVM_EXPECTED_PGREP_PATH" ]]; then
  : > "$MACKVM_PGREP_UNEXPECTED_LOG"
  printf 'Unexpected pgrep query:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 64
fi

# The app is deliberately not launched in CI, so report no matching process.
exit 1
PGREP
chmod 755 "$fake_bin/pgrep"

mkdir -p "$target_dir"
PATH="$fake_bin:$PATH" \
  MACKVM_EXPECTED_PGREP_PATH="$target_binary" \
  MACKVM_PGREP_LOG="$pgrep_log" \
  MACKVM_PGREP_UNEXPECTED_LOG="$unexpected_pgrep_log" \
  "$project_root/scripts/install-app.sh" \
    --source "$source_app" \
    --target-dir "$target_dir" >/dev/null

[[ ! -e "$pgrep_log" ]] || {
  echo "A fresh installation unexpectedly queried process state." >&2
  exit 1
}
[[ -d "$target_app" ]] || {
  echo "Installer did not create the app bundle." >&2
  exit 1
}
[[ -x "$target_binary" ]] || {
  echo "Installed app executable is missing or not executable." >&2
  exit 1
}

PATH="$fake_bin:$PATH" \
  MACKVM_EXPECTED_PGREP_PATH="$target_binary" \
  MACKVM_PGREP_LOG="$pgrep_log" \
  MACKVM_PGREP_UNEXPECTED_LOG="$unexpected_pgrep_log" \
  "$project_root/scripts/uninstall-app.sh" --target-dir "$target_dir" >/dev/null

[[ ! -e "$target_app" ]] || {
  echo "Uninstaller did not remove the app bundle." >&2
  exit 1
}
[[ -f "$pgrep_log" ]] || {
  echo "Uninstaller did not use the isolated pgrep fixture." >&2
  exit 1
}
expected_pgrep_call="-f"$'\t'"$target_binary"
expected_pgrep_log="argc=2"$'\t'"$expected_pgrep_call"
[[ ! -e "$unexpected_pgrep_log" && "$(<"$pgrep_log")" == "$expected_pgrep_log" ]] || {
  echo "Uninstaller did not query only the exact installed app binary." >&2
  exit 1
}

echo "Installer/uninstaller integration passed; process state was simulated for the exact installed binary and the app was not launched."
