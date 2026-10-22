#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_root"

source "$project_root/scripts/lib/build-environment.sh"
original_arguments=("$@")
original_argument_count=$#

usage() {
  cat >&2 <<'EOF'
Usage: scripts/ci.sh [--clean|--quick]

The default runs the full validation gate and reuses project-local caches.
--clean clears .build first, then runs the same full gate.
--quick runs the native Swift suite and focused shell/tooling fixtures while
skipping cross-architecture app/DDC builds and the Windows SDK suite.
EOF
}

clean_cache=false
quick_mode=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      clean_cache=true
      shift
      ;;
    --quick)
      quick_mode=true
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

if [[ "$original_argument_count" -eq 0 ]]; then
  mackvm_enter_build_lock "$project_root" "$project_root/scripts/ci.sh"
else
  mackvm_enter_build_lock "$project_root" "$project_root/scripts/ci.sh" "${original_arguments[@]}"
fi
mackvm_select_xcode
"$project_root/scripts/check-environment.sh"

if [[ "$clean_cache" == true ]]; then
  ./scripts/clean-build.sh
fi

export CLANG_MODULE_CACHE_PATH="$project_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift_bin="$MACKVM_SWIFT_PATH"

"$swift_bin" build --disable-sandbox
"$swift_bin" test --disable-sandbox
./scripts/test-install-app.sh

if [[ "$quick_mode" == true ]]; then
  ./scripts/test-build-tools.sh
  ./scripts/test-uninstall-app.sh
  bash -n \
    scripts/build-app.sh \
    scripts/build-ddc-diagnostic.sh \
    scripts/build-windows-macos.sh \
    scripts/check-environment.sh \
    scripts/clean-build.sh \
    scripts/clean-artifacts.sh \
    scripts/with-build-lock.sh \
    scripts/lib/build-environment.sh \
    scripts/test-build-tools.sh \
    scripts/test-install-app.sh \
    scripts/test-install-uninstall-integration.sh \
    scripts/package-notarized-dmg.sh \
    scripts/package-dmg.sh \
    scripts/compose-dmg.sh \
    scripts/test-package-notarized-dmg.sh
  ./scripts/test-package-notarized-dmg.sh
  echo "Quick mode skipped cross-architecture app/DDC builds and the Windows SDK suite."
  exit 0
fi

# Lock, cleanup, and Xcode-selection behavior are part of both validation
# modes, including the default full gate.
./scripts/test-build-tools.sh

# Exercise both the documented native output and the two supported release
# architectures. Cross-build validation is intentionally part of CI because
# releases are distributed to both Apple Silicon and Intel Macs.
./scripts/build-app.sh --no-clean
./scripts/build-app.sh --arch arm64 --no-clean
./scripts/build-app.sh --arch x86_64 --no-clean

# Exercise the checked-in installer and uninstaller against the arm64 bundle
# without touching /Applications or the user's preferences. Process state is
# simulated for the uninstaller's exact temporary binary path because CI does
# not launch the app and must not depend on host process enumeration.
./scripts/test-install-uninstall-integration.sh

./scripts/test-uninstall-app.sh

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
  windows_build_dir="$project_root/.build/windows-ci"
  mkdir -p "$windows_build_dir" "$project_root/.build/dotnet-home" \
    "$project_root/.build/nuget-packages"
  export DOTNET_CLI_HOME="$project_root/.build/dotnet-home"
  export NUGET_PACKAGES="$project_root/.build/nuget-packages"
  export DOTNET_CLI_TELEMETRY_OPTOUT=1
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

bash -n scripts/install-app.sh scripts/uninstall-app.sh \
  scripts/test-install-app.sh scripts/test-install-uninstall-integration.sh \
  scripts/test-uninstall-app.sh
./scripts/install-app.sh --help >/dev/null
./scripts/uninstall-app.sh --help >/dev/null

# Exercise the release adapter with mocked signing, notary, and packaging
# tools. Never invoke the real release command from CI: a developer machine
# may have the shared Codex credentials configured.
./scripts/package-notarized-dmg.sh --help >/dev/null
./scripts/package-dmg.sh --help >/dev/null
bash -n \
  scripts/package-notarized-dmg.sh \
  scripts/package-dmg.sh \
  scripts/compose-dmg.sh \
  scripts/test-package-notarized-dmg.sh
./scripts/test-package-notarized-dmg.sh
