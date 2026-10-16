#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_root"

usage() {
  cat <<'EOF'
Usage: scripts/build-windows-macos.sh [--arch x64|arm64|both]
       [--configuration debug|release] [--output PATH] [--plan]

Cross-publish the WindowsKVM self-contained, single-file Windows executable
from macOS. By default both Windows architectures are published to
dist/windows/<architecture>, and the existing dist directory is cleaned once.
An explicit --output replaces only that output directory.
Custom output paths must be children of this repository's dist/ directory.

--plan prints the publish commands without invoking .NET or changing files.
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

requested_arch="both"
configuration="release"
requested_output=""
output_was_default=true
plan_only=false
original_arguments=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      requested_arch="$2"
      shift 2
      ;;
    --arch=*)
      requested_arch="${1#--arch=}"
      [[ -n "$requested_arch" ]] || { usage >&2; exit 2; }
      shift
      ;;
    --configuration)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      configuration="$2"
      shift 2
      ;;
    --configuration=*)
      configuration="${1#--configuration=}"
      [[ -n "$configuration" ]] || { usage >&2; exit 2; }
      shift
      ;;
    --output)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      requested_output="$2"
      output_was_default=false
      shift 2
      ;;
    --output=*)
      requested_output="${1#--output=}"
      [[ -n "$requested_output" ]] || { usage >&2; exit 2; }
      output_was_default=false
      shift
      ;;
    --plan)
      plan_only=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$requested_arch" in
  x64|arm64|both) ;;
  *) echo "Unsupported architecture: $requested_arch (use x64, arm64, or both)." >&2; exit 2 ;;
esac
case "$configuration" in
  debug|release) ;;
  *) echo "Unsupported configuration: $configuration (use debug or release)." >&2; exit 2 ;;
esac
configuration_name="$(printf '%s' "$configuration" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }')"

if [[ "$project_root" == "/" || -z "$project_root" ]]; then
  fail "Refusing to build from an empty or filesystem-root project path."
fi

source "$project_root/scripts/lib/build-environment.sh"

project_path="$project_root/WindowsKVM/src/WindowsKVM.Desktop/WindowsKVM.Desktop.csproj"
[[ -f "$project_path" ]] || fail "Windows project not found: $project_path"

path_is_child() {
  local candidate="$1"
  local parent="$2"
  [[ "$candidate" == "$parent/"* ]]
}

normalize_lexical_path() {
  local input="$1"
  local rest component normalized="/"
  [[ "$input" == /* ]] || input="$project_root/$input"
  rest="${input#/}"
  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"
    if [[ "$rest" == */* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
    case "$component" in
      ""|.) ;;
      ..)
        normalized="${normalized%/*}"
        [[ -n "$normalized" ]] || normalized="/"
        ;;
      *)
        if [[ "$normalized" == "/" ]]; then
          normalized="/$component"
        else
          normalized="$normalized/$component"
        fi
        ;;
    esac
  done
  printf '%s\n' "$normalized"
}

canonicalize_output_without_creating() {
  local lexical_path="$1"
  local existing_path suffix="" component canonical_parent

  if [[ -L "$lexical_path" ]]; then
    fail "Refusing to clean an output path that is a symlink: $lexical_path"
  fi
  if [[ -e "$lexical_path" ]]; then
    [[ -d "$lexical_path" ]] || fail "Output path is not a directory: $lexical_path"
    (cd -P -- "$lexical_path" && pwd -P)
    return
  fi

  existing_path="$lexical_path"
  while [[ ! -e "$existing_path" && ! -L "$existing_path" ]]; do
    [[ "$existing_path" != "/" ]] || fail "Could not resolve output path: $lexical_path"
    component="${existing_path##*/}"
    if [[ -n "$suffix" ]]; then
      suffix="$component/$suffix"
    else
      suffix="$component"
    fi
    existing_path="${existing_path%/*}"
    [[ -n "$existing_path" ]] || existing_path="/"
  done

  [[ -d "$existing_path" ]] || fail "Output parent is not a directory: $existing_path"
  canonical_parent="$(cd -P -- "$existing_path" && pwd -P)"
  if [[ "$canonical_parent" == "/" ]]; then
    normalize_lexical_path "/$suffix"
  else
    normalize_lexical_path "$canonical_parent/$suffix"
  fi
}

validate_custom_output_path() {
  local lexical_path="$1"
  local canonical_path="$2"
  local home_path=""

  [[ "$canonical_path" != "/" ]] || fail "Refusing to clean a filesystem root."
  [[ "$canonical_path" != "$project_root" ]] || fail "Refusing to clean the repository root."
  [[ "$project_root" != "$canonical_path/"* ]] || fail "Refusing to clean a parent of the repository: $canonical_path"

  path_is_child "$lexical_path" "$project_root/dist" || \
    fail "A custom output must be a child of this repository's dist/ directory: $lexical_path"
  path_is_child "$canonical_path" "$project_root/dist" || \
    fail "A custom output must resolve to a child of this repository's dist/ directory: $canonical_path"
  [[ ! -L "$project_root/dist" ]] || \
    fail "Refusing a custom output through a symlinked dist directory."

  if [[ -n "${HOME:-}" && -d "$HOME" ]]; then
    home_path="$(cd -P -- "$HOME" && pwd -P)"
    [[ "$canonical_path" != "$home_path" ]] || fail "Refusing to clean the home directory."
    [[ "$home_path" != "$canonical_path/"* ]] || \
      fail "Refusing to clean a parent of the home directory: $canonical_path"
  fi
}

output_was_default_path="$output_was_default"
if [[ "$output_was_default" == true ]]; then
  output_directory="$project_root/dist/windows"
  output_lexical_path="$output_directory"
else
  [[ "$requested_output" != *$'\n'* ]] || fail "Output paths may not contain newlines."
  output_lexical_path="$(normalize_lexical_path "$requested_output")"
  output_directory="$(canonicalize_output_without_creating "$output_lexical_path")"
  validate_custom_output_path "$output_lexical_path" "$output_directory"
fi

architecture_labels=()
runtime_ids=()
case "$requested_arch" in
  x64)
    architecture_labels=(x64)
    runtime_ids=(win-x64)
    ;;
  arm64)
    architecture_labels=(arm64)
    runtime_ids=(win-arm64)
    ;;
  both)
    architecture_labels=(x64 arm64)
    runtime_ids=(win-x64 win-arm64)
    ;;
esac

build_state_root="$project_root/.build/windows-publish"
dotnet_cli_home="$project_root/.build/dotnet-home"
nuget_packages="$project_root/.build/nuget-packages"

preflight_build_directory() {
  local directory="$1"
  if [[ -L "$directory" ]]; then
    fail "Refusing a symlinked build-state directory: $directory"
  fi
  if [[ -e "$directory" && ! -d "$directory" ]]; then
    fail "Build-state path is not a directory: $directory"
  fi
}

if [[ "$plan_only" == true ]]; then
  echo "MacKVM Windows cross-publish plan"
  echo "  project:       $project_path"
  echo "  configuration: $configuration_name"
  echo "  output:        $output_directory"
  if [[ "$output_was_default_path" == true ]]; then
    echo "  cleanup:       replace $project_root/dist before publishing"
  else
    echo "  cleanup:       replace only $output_directory"
  fi
  for index in "${!runtime_ids[@]}"; do
    architecture_directory="$output_directory/${architecture_labels[$index]}"
    build_state_directory="$build_state_root/${runtime_ids[$index]}"
    command=(dotnet publish "$project_path" \
      --configuration "$configuration_name" \
      --runtime "${runtime_ids[$index]}" \
      -p:EnableWindowsTargeting=true \
      --self-contained true \
      -p:PublishSingleFile=true \
      -p:PublishTrimmed=false \
      --artifacts-path "$build_state_directory" \
      --output "$architecture_directory")
    printf '  %s: ' "${architecture_labels[$index]}"
    printf '%q ' "${command[@]}"
    printf '\n'
  done
  echo "Plan only: no .NET toolchain was invoked and no files were created, changed, or removed."
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "scripts/build-windows-macos.sh must publish from macOS. Use --plan to preview on another host."
fi

if [[ "$output_was_default_path" != true ]]; then
  validate_custom_output_path "$output_lexical_path" "$output_directory"
fi

# Serialize this operation with the other project build and cleanup scripts.
if [[ ${#original_arguments[@]} -eq 0 ]]; then
  mackvm_enter_build_lock "$project_root" "$project_root/scripts/build-windows-macos.sh"
else
  mackvm_enter_build_lock "$project_root" "$project_root/scripts/build-windows-macos.sh" "${original_arguments[@]}"
fi

command -v file >/dev/null 2>&1 || fail "The macOS 'file' utility is required to verify Windows PE outputs."
command -v dotnet >/dev/null 2>&1 || fail "dotnet was not found. Install the .NET 8 SDK or newer."

preflight_build_directory "$project_root/.build"
preflight_build_directory "$build_state_root"
preflight_build_directory "$dotnet_cli_home"
preflight_build_directory "$nuget_packages"
for runtime_id in "${runtime_ids[@]}"; do
  preflight_build_directory "$build_state_root/$runtime_id"
done

if [[ "$output_was_default_path" == true ]]; then
  dist_root="$project_root/dist"
  [[ "$dist_root" == "$project_root/dist" && "$project_root" != "/" ]] || \
    fail "Refusing to clean an unexpected default artifact path: $dist_root"
  if [[ -L "$dist_root" ]]; then
    fail "Refusing to clean a symlinked dist directory: $dist_root"
  fi
  if [[ -e "$dist_root" && ! -d "$dist_root" ]]; then
    fail "The default dist path is not a directory: $dist_root"
  fi
fi

mkdir -p -- "$project_root/.build" "$build_state_root" "$dotnet_cli_home" "$nuget_packages"
export DOTNET_CLI_HOME="$dotnet_cli_home"
export NUGET_PACKAGES="$nuget_packages"
export DOTNET_CLI_TELEMETRY_OPTOUT=1

if ! sdk_list="$(dotnet --list-sdks 2>&1)"; then
  fail "Could not list installed .NET SDKs: $sdk_list"
fi
supported_sdk="$(printf '%s\n' "$sdk_list" | awk '
  $1 ~ /^[0-9]+\./ {
    split($1, version, ".")
    if (version[1] >= 8) {
      print $1
      exit
    }
  }
')"
[[ -n "$supported_sdk" ]] || fail "A .NET 8 SDK or newer is required. Installed SDKs: ${sdk_list:-none}"

if [[ "$output_was_default_path" == true ]]; then
  dist_root="$project_root/dist"
  if [[ -e "$dist_root" ]]; then
    rm -rf -- "$dist_root"
  fi
  mkdir -p -- "$output_directory"
else
  if [[ -e "$output_directory" ]]; then
    [[ ! -L "$output_directory" && -d "$output_directory" ]] || \
      fail "Refusing to replace an output path that is not a real directory: $output_directory"
    resolved_output="$(cd -P -- "$output_directory" && pwd -P)"
    [[ "$resolved_output" == "$output_directory" ]] || \
      fail "Output directory changed while being prepared: $output_directory"
    rm -rf -- "$output_directory"
  fi
  mkdir -p -- "$output_directory"
  [[ ! -L "$output_directory" && -d "$output_directory" ]] || \
    fail "Could not safely create the output directory: $output_directory"
  resolved_output="$(cd -P -- "$output_directory" && pwd -P)"
  [[ "$resolved_output" == "$output_directory" ]] || \
    fail "Output directory resolved unexpectedly: $resolved_output"
fi

for index in "${!runtime_ids[@]}"; do
  label="${architecture_labels[$index]}"
  runtime_id="${runtime_ids[$index]}"
  state_directory="$build_state_root/$runtime_id"
  architecture_directory="$output_directory/$label"

  preflight_build_directory "$state_directory"
  if [[ -e "$state_directory" ]]; then
    rm -rf -- "$state_directory"
  fi
  mkdir -p -- "$state_directory" "$architecture_directory"

  echo "Publishing WindowsKVM for $label ($runtime_id)..."
  if dotnet publish "$project_path" \
    --configuration "$configuration_name" \
    --runtime "$runtime_id" \
    -p:EnableWindowsTargeting=true \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:PublishTrimmed=false \
    --artifacts-path "$state_directory" \
    --output "$architecture_directory"; then
    :
  else
    publish_status=$?
    echo "dotnet publish failed for $runtime_id with exit code $publish_status." >&2
    exit "$publish_status"
  fi

  executable="$architecture_directory/WindowsKVM.exe"
  [[ -f "$executable" && ! -L "$executable" ]] || \
    fail "Expected published executable was not found: $executable"
  executable_count="$(find "$architecture_directory" -type f -name '*.exe' -print | wc -l | tr -d '[:space:]')"
  [[ "$executable_count" == "1" ]] || \
    fail "Expected exactly one Windows executable in $architecture_directory; found $executable_count."

  if ! file_description="$(file -b -- "$executable" 2>&1)"; then
    fail "Could not inspect $executable with file: $file_description"
  fi
  case "$file_description" in
    "PE32+ executable"*) ;;
    *) fail "Published output is not a 64-bit Windows PE executable: $executable ($file_description)" ;;
  esac

  normalized_description="$(printf '%s' "$file_description" | tr '[:upper:]' '[:lower:]')"
  case "$label" in
    x64)
      case "$normalized_description" in
        *x86-64*|*x86_64*) ;;
        *) fail "Expected an x64 Windows PE binary, but $executable is: $file_description" ;;
      esac
      ;;
    arm64)
      case "$normalized_description" in
        *aarch64*|*arm64*) ;;
        *) fail "Expected an ARM64 Windows PE binary, but $executable is: $file_description" ;;
      esac
      ;;
  esac

  echo "Published $executable ($label; $file_description)"
done
