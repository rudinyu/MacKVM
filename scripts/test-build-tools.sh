#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/mackvm-build-tools.XXXXXX")"
test_root="$(cd -P "$test_root" && pwd -P)"
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

# Build-tool fixtures represent another checkout and must not inherit a lock
# owned by the repository that is running this test.
unset MACKVM_BUILD_LOCK_DIR MACKVM_BUILD_LOCK_TOKEN
export MACKVM_BUILD_LOCK_WAIT_SECONDS=10

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

fixture_project="$test_root/project"
fixture_scripts="$fixture_project/scripts"
mkdir -p "$fixture_scripts/lib"
cp \
  "$project_root/scripts/clean-build.sh" \
  "$project_root/scripts/clean-artifacts.sh" \
  "$project_root/scripts/with-build-lock.sh" \
  "$fixture_scripts/"
cp "$project_root/scripts/lib/build-environment.sh" "$fixture_scripts/lib/"
chmod 755 \
  "$fixture_scripts/clean-build.sh" \
  "$fixture_scripts/clean-artifacts.sh" \
  "$fixture_scripts/with-build-lock.sh"

mkdir -p "$fixture_project/.build/swift-state" "$fixture_project/dist"
printf 'keep this release\n' > "$fixture_project/dist/MacKVM-1.0-universal.dmg"
"$fixture_scripts/clean-build.sh" --help >/dev/null
"$fixture_scripts/clean-artifacts.sh" --help >/dev/null
[[ ! -e "$fixture_project/.mackvm-build.lock" ]] || \
  fail "a help request acquired the shared build lock"
if "$fixture_scripts/clean-build.sh" invalid-argument >/dev/null 2>&1; then
  fail "cache cleanup accepted an invalid argument"
else
  invalid_status=$?
fi
[[ "$invalid_status" -eq 2 ]] || \
  fail "invalid cleanup argument returned $invalid_status instead of 2"
[[ ! -e "$fixture_project/.mackvm-build.lock" ]] || \
  fail "an invalid argument acquired the shared build lock"
"$fixture_scripts/clean-build.sh" >/dev/null
[[ ! -e "$fixture_project/.build" ]] || fail "cache cleanup left .build behind"
[[ -f "$fixture_project/dist/MacKVM-1.0-universal.dmg" ]] || \
  fail "cache cleanup deleted a retained dist deliverable"

mkdir -p "$fixture_project/.build/other-cache"
"$fixture_scripts/clean-artifacts.sh" >/dev/null
[[ ! -e "$fixture_project/dist" && ! -L "$fixture_project/dist" ]] || \
  fail "explicit artifact cleanup left dist behind"
[[ -d "$fixture_project/.build/other-cache" ]] || \
  fail "artifact cleanup deleted the build cache"
rm -rf -- "$fixture_project/.build"
[[ ! -e "$fixture_project/.mackvm-build.lock" ]] || \
  fail "cleanup left the shared build lock behind"

cat > "$fixture_scripts/locked-work.sh" <<'LOCKED_WORK'
#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_root/scripts/lib/build-environment.sh"
mackvm_build_lock_is_held "$project_root" || {
  echo "nested command did not inherit a valid build lock" >&2
  exit 1
}
mkdir "$MACKVM_TEST_ACTIVE_DIR" || {
  echo "two build commands entered the critical section at once" >&2
  exit 1
}
sleep 0.2
rmdir "$MACKVM_TEST_ACTIVE_DIR"
printf '%s\n' "$1" >> "$MACKVM_TEST_LOG"
LOCKED_WORK

cat > "$fixture_scripts/nested-entry.sh" <<'NESTED_ENTRY'
#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
"$project_root/scripts/with-build-lock.sh" \
  "$project_root/scripts/locked-work.sh" "$1"
NESTED_ENTRY
chmod 755 "$fixture_scripts/locked-work.sh" "$fixture_scripts/nested-entry.sh"

export MACKVM_TEST_ACTIVE_DIR="$fixture_project/.active-build"
export MACKVM_TEST_LOG="$fixture_project/build-order.log"
: > "$MACKVM_TEST_LOG"
"$fixture_scripts/with-build-lock.sh" "$fixture_scripts/nested-entry.sh" first \
  > "$fixture_project/first.log" 2>&1 &
first_pid=$!
"$fixture_scripts/with-build-lock.sh" "$fixture_scripts/nested-entry.sh" second \
  > "$fixture_project/second.log" 2>&1 &
second_pid=$!
first_status=0
second_status=0
wait "$first_pid" || first_status=$?
wait "$second_pid" || second_status=$?
[[ "$first_status" -eq 0 && "$second_status" -eq 0 ]] || {
  cat "$fixture_project/first.log" "$fixture_project/second.log" >&2
  fail "concurrent build-lock regression returned $first_status/$second_status"
}
[[ ! -e "$MACKVM_TEST_ACTIVE_DIR" ]] || fail "critical-section marker was not removed"
[[ ! -e "$fixture_project/.mackvm-build.lock" ]] || \
  fail "concurrent commands left the shared build lock behind"
[[ "$(wc -l < "$MACKVM_TEST_LOG" | tr -d ' ')" == 2 ]] || \
  fail "expected both serialized commands to complete"
grep -Fx 'first' "$MACKVM_TEST_LOG" >/dev/null || fail "first command was lost"
grep -Fx 'second' "$MACKVM_TEST_LOG" >/dev/null || fail "second command was lost"

mkdir "$fixture_project/.mackvm-build.lock"
printf 'fixture-owner stale-fixture-token\n' > "$fixture_project/.mackvm-build.lock/owner"
if timeout_output="$(MACKVM_BUILD_LOCK_WAIT_SECONDS=1 \
  "$fixture_scripts/with-build-lock.sh" "$fixture_scripts/locked-work.sh" timeout 2>&1)"; then
  fail "an occupied build lock unexpectedly allowed a command to enter"
else
  timeout_status=$?
fi
[[ "$timeout_status" -eq 75 ]] || \
  fail "lock wait returned $timeout_status instead of 75"
assert_contains "$timeout_output" "Timed out waiting for the MacKVM build lock"
assert_contains "$timeout_output" "owner PID: fixture-owner"
rm -rf -- "$fixture_project/.mackvm-build.lock"

cat > "$fixture_scripts/failing-work.sh" <<'FAIL'
#!/usr/bin/env bash
exit 47
FAIL
chmod 755 "$fixture_scripts/failing-work.sh"
if "$fixture_scripts/with-build-lock.sh" "$fixture_scripts/failing-work.sh" \
  > "$fixture_project/failure.log" 2>&1; then
  fail "failing child command unexpectedly succeeded"
else
  failure_status=$?
fi
[[ "$failure_status" -eq 47 ]] || \
  fail "failing child returned $failure_status instead of 47"
[[ ! -e "$fixture_project/.mackvm-build.lock" ]] || \
  fail "failed child command left the shared build lock behind"

fake_xcode_app="$test_root/Xcode.app"
fake_developer_dir="$fake_xcode_app/Contents/Developer"
fake_toolchain="$fake_developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
mock_bin="$test_root/mock-bin"
mkdir -p \
  "$fake_developer_dir/usr/bin" \
  "$fake_developer_dir/Platforms/MacOSX.platform" \
  "$fake_developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
  "$fake_toolchain" \
  "$mock_bin"
cat > "$fake_developer_dir/usr/bin/xcodebuild" <<'XCODEBUILD'
#!/usr/bin/env bash
printf 'Xcode 27.0\nBuild version 27A1\n'
XCODEBUILD
cat > "$fake_toolchain/swift" <<'SWIFT'
#!/usr/bin/env bash
printf 'Apple Swift version 6.2 (swiftlang-6.2.0.1.3 clang-1700.0.13.3)\n'
SWIFT
cat > "$fake_toolchain/clang" <<'CLANG'
#!/usr/bin/env bash
exit 0
CLANG
cat > "$mock_bin/xcrun" <<'XCRUN'
#!/usr/bin/env bash
if [[ "${1:-}" == --find && $# -eq 2 ]]; then
  printf '%s/Toolchains/XcodeDefault.xctoolchain/usr/bin/%s\n' \
    "$DEVELOPER_DIR" "$2"
elif [[ "${1:-}" == --sdk && "${2:-}" == macosx && \
        "${3:-}" == --show-sdk-path && $# -eq 3 ]]; then
  printf '%s/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk\n' \
    "$DEVELOPER_DIR"
else
  exit 2
fi
XCRUN
chmod 755 \
  "$fake_developer_dir/usr/bin/xcodebuild" \
  "$fake_toolchain/swift" \
  "$fake_toolchain/clang" \
  "$mock_bin/xcrun"

selection_output="$(
  export PATH="$mock_bin:$PATH"
  export DEVELOPER_DIR="$fake_xcode_app"
  source "$project_root/scripts/lib/build-environment.sh"
  mackvm_select_xcode
  printf '%s\n%s\n%s\n%s\n' \
    "$DEVELOPER_DIR" "$MACKVM_XCODE_VERSION" "$MACKVM_SWIFT_PATH" \
    "$MACKVM_MACOS_SDK_PATH"
)"
assert_contains "$selection_output" "$fake_developer_dir"
assert_contains "$selection_output" "Xcode 27.0"
assert_contains "$selection_output" "$fake_toolchain/swift"
assert_contains "$selection_output" "$fake_developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

if invalid_output="$(
  export PATH="$mock_bin:$PATH"
  export DEVELOPER_DIR="$test_root/not-an-xcode"
  source "$project_root/scripts/lib/build-environment.sh"
  mackvm_select_xcode 2>&1
)"; then
  fail "invalid explicit DEVELOPER_DIR was accepted"
fi
assert_contains "$invalid_output" "DEVELOPER_DIR is set but does not point to a usable full Xcode installation"

windows_fixture="$test_root/windows-cross-publish"
windows_scripts="$windows_fixture/scripts"
windows_mock_bin="$test_root/windows-mock-bin"
mkdir -p \
  "$windows_scripts/lib" \
  "$windows_fixture/WindowsKVM/src/WindowsKVM.Desktop" \
  "$windows_fixture/dist" \
  "$windows_mock_bin"
cp \
  "$project_root/scripts/build-windows-macos.sh" \
  "$project_root/scripts/with-build-lock.sh" \
  "$windows_scripts/"
cp "$project_root/scripts/lib/build-environment.sh" "$windows_scripts/lib/"
chmod 755 "$windows_scripts/build-windows-macos.sh" "$windows_scripts/with-build-lock.sh"
printf '<Project />\n' > \
  "$windows_fixture/WindowsKVM/src/WindowsKVM.Desktop/WindowsKVM.Desktop.csproj"

cat > "$windows_mock_bin/uname" <<'UNAME'
#!/usr/bin/env bash
if [[ "${1:-}" == -s ]]; then
  printf 'Darwin\n'
else
  exec /usr/bin/uname "$@"
fi
UNAME
cat > "$windows_mock_bin/dotnet" <<'DOTNET'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --list-sdks ]]; then
  printf '10.0.402 [fixture]\n'
  exit 0
fi
[[ "${1:-}" == publish ]] || exit 91
printf '%s\n' "$*" >> "$MACKVM_TEST_DOTNET_LOG"
if [[ "${MACKVM_TEST_FAIL_PUBLISH:-0}" == 1 ]]; then
  exit 37
fi
runtime_id=""
output_directory=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      runtime_id="$2"
      shift 2
      ;;
    --output)
      output_directory="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done
mkdir -p "$output_directory"
if [[ "${MACKVM_TEST_MISSING_EXE:-0}" == 1 ]]; then
  exit 0
fi
printf '%s\n' "$runtime_id" > "$output_directory/WindowsKVM.exe"
if [[ "${MACKVM_TEST_EXTRA_EXE:-0}" == 1 ]]; then
  printf 'unexpected\n' > "$output_directory/Unexpected.exe"
fi
DOTNET
cat > "$windows_mock_bin/file" <<'FILE'
#!/usr/bin/env bash
set -euo pipefail
path=""
for argument in "$@"; do
  path="$argument"
done
[[ -n "$path" ]] || exit 2
if [[ "${MACKVM_TEST_WRONG_PE:-0}" == 1 ]]; then
  printf 'ELF 64-bit LSB executable\n'
  exit 0
fi
runtime_id="$(<"$path")"
if [[ "${MACKVM_TEST_WRONG_ARCH:-0}" == 1 ]]; then
  runtime_id=win-arm64
fi
case "$runtime_id" in
  win-x64) printf 'PE32+ executable (console) x86-64, for MS Windows\n' ;;
  win-arm64) printf 'PE32+ executable (GUI) AArch64, for MS Windows\n' ;;
  *) printf 'unknown fixture output\n' ;;
esac
FILE
chmod 755 "$windows_mock_bin/uname" "$windows_mock_bin/dotnet" "$windows_mock_bin/file"
windows_dotnet_log="$windows_fixture/dotnet-arguments.log"
export MACKVM_TEST_DOTNET_LOG="$windows_dotnet_log"

bash -n "$windows_scripts/build-windows-macos.sh"
"$windows_scripts/build-windows-macos.sh" --help >/dev/null
printf 'retain plan output\n' > "$windows_fixture/dist/keep-before-plan.txt"
windows_plan_output="$("$windows_scripts/build-windows-macos.sh" --plan)"
assert_contains "$windows_plan_output" "-p:EnableWindowsTargeting=true"
assert_contains "$windows_plan_output" "--runtime win-x64"
assert_contains "$windows_plan_output" "--runtime win-arm64"
assert_contains "$windows_plan_output" "PublishSingleFile=true"
assert_contains "$windows_plan_output" "Plan only: no .NET toolchain was invoked"
[[ -f "$windows_fixture/dist/keep-before-plan.txt" ]] || \
  fail "Windows cross-publish plan removed existing dist content"
[[ ! -e "$windows_fixture/.build" ]] || \
  fail "Windows cross-publish plan created build state"

if "$windows_scripts/build-windows-macos.sh" --output . --plan \
  > "$windows_fixture/unsafe-plan.log" 2>&1; then
  fail "Windows cross-publish accepted the repository root as a custom output"
else
  unsafe_plan_status=$?
fi
[[ "$unsafe_plan_status" -ne 0 ]] || \
  fail "Unsafe Windows cross-publish output returned success"

if "$windows_scripts/build-windows-macos.sh" --output "$windows_fixture/dist" --plan \
  > "$windows_fixture/dist-root-plan.log" 2>&1; then
  fail "Windows cross-publish accepted dist itself as a custom output"
else
  dist_root_plan_status=$?
fi
[[ "$dist_root_plan_status" -ne 0 ]] || \
  fail "dist root was accepted as a custom Windows cross-publish output"

if "$windows_scripts/build-windows-macos.sh" --output /tmp --plan \
  > "$windows_fixture/tmp-plan.log" 2>&1; then
  fail "Windows cross-publish accepted /tmp as a custom output"
else
  tmp_plan_status=$?
fi
[[ "$tmp_plan_status" -ne 0 ]] || \
  fail "/tmp was accepted as a custom Windows cross-publish output"

outside_output="$test_root/outside-windows-output"
mkdir -p "$outside_output"
printf 'outside destination must remain intact\n' > "$outside_output/sentinel.txt"
if PATH="$windows_mock_bin:$PATH" \
  "$windows_scripts/build-windows-macos.sh" --arch x64 --output "$outside_output" \
  > "$windows_fixture/outside-output.log" 2>&1; then
  fail "Windows cross-publish accepted an outside-repository custom output"
else
  outside_output_status=$?
fi
[[ "$outside_output_status" -ne 0 ]] || \
  fail "Outside-repository custom output returned success"
[[ "$(<"$outside_output/sentinel.txt")" == "outside destination must remain intact" ]] || \
  fail "Rejecting an outside output modified its existing sentinel"
assert_contains "$(<"$windows_fixture/outside-output.log")" \
  "must be a child of this repository's dist/ directory"

printf 'remove for default clean\n' > "$windows_fixture/dist/remove-on-build.txt"
windows_build_output="$(PATH="$windows_mock_bin:$PATH" \
  "$windows_scripts/build-windows-macos.sh" --arch both 2>&1)" || {
  printf '%s\n' "$windows_build_output" >&2
  fail "mocked Windows cross-publish failed"
}
assert_contains "$windows_build_output" "Published $windows_fixture/dist/windows/x64/WindowsKVM.exe (x64"
assert_contains "$windows_build_output" "Published $windows_fixture/dist/windows/arm64/WindowsKVM.exe (arm64"
[[ ! -e "$windows_fixture/dist/remove-on-build.txt" ]] || \
  fail "Default Windows cross-publish did not clean dist"
[[ -f "$windows_fixture/dist/windows/x64/WindowsKVM.exe" ]] || \
  fail "Windows x64 executable was not published"
[[ -f "$windows_fixture/dist/windows/arm64/WindowsKVM.exe" ]] || \
  fail "Windows ARM64 executable was not published"
[[ -d "$windows_fixture/.build/windows-publish/win-x64" && \
   -d "$windows_fixture/.build/windows-publish/win-arm64" ]] || \
  fail "Windows cross-publish did not isolate state per runtime identifier"
assert_contains "$(<"$windows_dotnet_log")" "-p:EnableWindowsTargeting=true"
assert_contains "$(<"$windows_dotnet_log")" "--self-contained true"
assert_contains "$(<"$windows_dotnet_log")" "-p:PublishSingleFile=true"
assert_contains "$(<"$windows_dotnet_log")" "-p:PublishTrimmed=false"

printf 'preserve other dist content\n' > "$windows_fixture/dist/keep-on-custom-build.txt"
mkdir -p "$windows_fixture/dist/windows-local"
printf 'stale custom output\n' > "$windows_fixture/dist/windows-local/stale.txt"
PATH="$windows_mock_bin:$PATH" \
  "$windows_scripts/build-windows-macos.sh" --arch x64 --output dist/windows-local \
  > /dev/null
[[ -f "$windows_fixture/dist/keep-on-custom-build.txt" ]] || \
  fail "Custom Windows cross-publish cleaned unrelated dist content"
[[ -f "$windows_fixture/dist/windows/arm64/WindowsKVM.exe" ]] || \
  fail "Custom Windows cross-publish removed the prior default output"
[[ ! -e "$windows_fixture/dist/windows-local/stale.txt" ]] || \
  fail "Custom Windows cross-publish did not clean its selected output"
[[ -f "$windows_fixture/dist/windows-local/x64/WindowsKVM.exe" ]] || \
  fail "Custom Windows cross-publish did not create the requested architecture output"

if PATH="$windows_mock_bin:$PATH" MACKVM_TEST_WRONG_ARCH=1 \
  "$windows_scripts/build-windows-macos.sh" --arch x64 --output dist/windows-wrong-arch \
  > "$windows_fixture/wrong-arch.log" 2>&1; then
  fail "Windows cross-publish accepted an unexpected PE architecture"
else
  wrong_arch_status=$?
fi
[[ "$wrong_arch_status" -ne 0 ]] || \
  fail "Unexpected Windows PE architecture returned success"
assert_contains "$(<"$windows_fixture/wrong-arch.log")" "Expected an x64 Windows PE binary"

if PATH="$windows_mock_bin:$PATH" MACKVM_TEST_WRONG_PE=1 \
  "$windows_scripts/build-windows-macos.sh" --arch x64 --output dist/windows-not-pe \
  > "$windows_fixture/not-pe.log" 2>&1; then
  fail "Windows cross-publish accepted a non-PE output"
else
  not_pe_status=$?
fi
[[ "$not_pe_status" -ne 0 ]] || fail "Non-PE output returned success"
assert_contains "$(<"$windows_fixture/not-pe.log")" "not a 64-bit Windows PE executable"

if PATH="$windows_mock_bin:$PATH" MACKVM_TEST_MISSING_EXE=1 \
  "$windows_scripts/build-windows-macos.sh" --arch arm64 --output dist/windows-missing \
  > "$windows_fixture/missing-exe.log" 2>&1; then
  fail "Windows cross-publish accepted a missing executable"
else
  missing_exe_status=$?
fi
[[ "$missing_exe_status" -ne 0 ]] || fail "Missing executable returned success"
assert_contains "$(<"$windows_fixture/missing-exe.log")" "Expected published executable was not found"

if PATH="$windows_mock_bin:$PATH" MACKVM_TEST_EXTRA_EXE=1 \
  "$windows_scripts/build-windows-macos.sh" --arch x64 --output dist/windows-extra \
  > "$windows_fixture/extra-exe.log" 2>&1; then
  fail "Windows cross-publish accepted an unexpected extra executable"
else
  extra_exe_status=$?
fi
[[ "$extra_exe_status" -ne 0 ]] || fail "Unexpected extra executable returned success"
assert_contains "$(<"$windows_fixture/extra-exe.log")" "Expected exactly one Windows executable"

if PATH="$windows_mock_bin:$PATH" MACKVM_TEST_FAIL_PUBLISH=1 \
  "$windows_scripts/build-windows-macos.sh" --arch x64 --output dist/windows-publish-failure \
  > "$windows_fixture/publish-failure.log" 2>&1; then
  fail "Windows cross-publish ignored a failed dotnet publish"
else
  publish_failure_status=$?
fi
[[ "$publish_failure_status" -eq 37 ]] || \
  fail "dotnet publish failure returned $publish_failure_status instead of 37"
assert_contains "$(<"$windows_fixture/publish-failure.log")" "dotnet publish failed for win-x64"

echo "Build environment and cleanup tests passed."
