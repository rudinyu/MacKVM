#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

# CI is one multi-target build batch. Clean once here, then keep the outputs
# while each architecture and diagnostic target is produced below.
./scripts/clean-build.sh

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

export CLANG_MODULE_CACHE_PATH="$project_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

swift build --disable-sandbox
swift test --disable-sandbox

# Exercise both the documented native output and the two supported release
# architectures. Cross-build validation is intentionally part of CI because
# releases are distributed to both Apple Silicon and Intel Macs.
./scripts/build-app.sh --no-clean
./scripts/build-app.sh --arch arm64 --no-clean
./scripts/build-app.sh --arch x86_64 --no-clean

# Exercise the checked-in installer and uninstaller against the arm64 bundle
# without touching /Applications or the user's preferences.
installer_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/mackvm-installer.XXXXXX")"
cleanup_installer_test() {
  rm -rf -- "$installer_test_dir"
}
trap cleanup_installer_test EXIT
./scripts/install-app.sh \
  --source "$project_root/dist/arm64/MacKVM.app" \
  --target-dir "$installer_test_dir" >/dev/null
[[ -d "$installer_test_dir/MacKVM.app" ]] || {
  echo "Installer did not create the app bundle." >&2
  exit 1
}
./scripts/uninstall-app.sh --target-dir "$installer_test_dir" >/dev/null
[[ ! -e "$installer_test_dir/MacKVM.app" ]] || {
  echo "Uninstaller did not remove the app bundle." >&2
  exit 1
}
cleanup_installer_test
trap - EXIT

./scripts/build-ddc-diagnostic.sh --arch arm64 --no-clean
./scripts/build-ddc-diagnostic.sh --arch x86_64 --no-clean
./scripts/build-ddc-diagnostic.sh --arch universal --no-clean
./dist/ddc-diagnostic-universal --help >/dev/null

# The Windows protocol and desktop production-path self-tests are framework
# neutral and inject native desktop boundaries, so they can run on this macOS
# build host without a Windows VM. Run them automatically
# when a .NET SDK is available, but keep the macOS validation useful on a clean
# Mac that only has the Swift/Xcode prerequisites. Set RUN_WINDOWS_CI=1 in
# required environments (such as GitHub Actions) to turn a missing SDK into a
# hard failure instead of a deliberate local skip.
run_windows_ci="${RUN_WINDOWS_CI:-auto}"
if [[ "$run_windows_ci" == "1" || "$run_windows_ci" == "true" ]]; then
  windows_ci_required=true
elif [[ "$run_windows_ci" == "0" || "$run_windows_ci" == "false" ]]; then
  windows_ci_required=false
else
  windows_ci_required=false
fi

dotnet_sdk_available=false
if command -v dotnet >/dev/null 2>&1 \
  && dotnet --list-sdks 2>/dev/null | awk '
      {
        split($1, version, ".")
        if (version[1] ~ /^[0-9]+$/ && version[1] >= 8) {
          found = 1
        }
      }
      END { exit(found ? 0 : 1) }
    '; then
  dotnet_sdk_available=true
fi

if [[ "$run_windows_ci" != "0" && "$run_windows_ci" != "false" ]] \
  && "$dotnet_sdk_available"; then
  windows_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/mackvm-windows-ci.XXXXXX")"
  trap 'rm -rf "$windows_build_dir"' EXIT
  case "$(uname -m)" in
    arm64|aarch64)
      windows_test_runtime=osx-arm64
      ;;
    x86_64|amd64)
      windows_test_runtime=osx-x64
      ;;
    *)
      echo "Unsupported host architecture for the Windows self-tests." >&2
      exit 1
      ;;
  esac
  dotnet build \
    WindowsKVM/src/WindowsKVM.Desktop/WindowsKVM.Desktop.csproj \
    --configuration Release \
    -p:EnableWindowsTargeting=true \
    --artifacts-path "$windows_build_dir/Desktop-build"
  for windows_test_suite in Protocol Desktop; do
    windows_test_name="WindowsKVM.$windows_test_suite.SelfTest"
    windows_test_output="$windows_build_dir/$windows_test_suite"
    dotnet publish \
      "WindowsKVM/tests/$windows_test_name/$windows_test_name.csproj" \
      --configuration Release \
      --runtime "$windows_test_runtime" \
      --self-contained true \
      --artifacts-path "$windows_build_dir/$windows_test_suite-build" \
      --output "$windows_test_output"
    "$windows_test_output/$windows_test_name"
  done
elif "$windows_ci_required"; then
  echo "A .NET 8 SDK (or newer) is required when RUN_WINDOWS_CI=1." >&2
  exit 1
else
  echo "Skipping Windows checks: a .NET 8 SDK was not found (set RUN_WINDOWS_CI=1 to require it)."
fi

assert_build_app_rejected() {
  local description="$1"
  shift

  if ./scripts/build-app.sh "$@" >/dev/null 2>&1; then
    echo "$description was unexpectedly accepted." >&2
    exit 1
  else
    local status=$?
  fi

  if [[ "$status" -ne 2 ]]; then
    echo "$description returned $status instead of 2." >&2
    exit 1
  fi
}

assert_build_app_rejected "Invalid architecture" --arch invalid
assert_build_app_rejected "Invalid equals-form architecture" --arch=invalid
assert_build_app_rejected "Missing architecture value" --arch

bash -n scripts/install-app.sh scripts/uninstall-app.sh
./scripts/install-app.sh --help >/dev/null
./scripts/uninstall-app.sh --help >/dev/null

# The notarized release path requires credentials and is intentionally not
# submitted during CI. Keep its command-line contract covered without
# contacting Apple's notary service.
./scripts/package-notarized-dmg.sh --help >/dev/null
if ./scripts/package-notarized-dmg.sh --arch universal >/dev/null 2>&1; then
  echo "Notarized packaging without signing credentials was unexpectedly accepted." >&2
  exit 1
else
  notarized_status=$?
fi
if [[ "$notarized_status" -ne 2 ]]; then
  echo "Notarized packaging missing credentials returned $notarized_status instead of 2." >&2
  exit 1
fi
