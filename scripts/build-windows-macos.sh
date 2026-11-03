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
The publish requires Python 3 to read the generated app .deps.json and
.runtimeconfig.json and stage the exact resolved .NET runtime notices.
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
  echo "  notices:       resolve runtime packs from publish .deps.json/.runtimeconfig.json; stage LICENSE.TXT and THIRD-PARTY-NOTICES.TXT"
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
command -v python3 >/dev/null 2>&1 || fail "Python 3 is required to read the publish .deps.json and .runtimeconfig.json and stage legal notices."
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

stage_resolved_runtime_notices() {
  local state_directory="$1"
  local runtime_id="$2"
  local architecture_directory="$3"
  local project_path="$4"

  if python3 - "$state_directory" "$runtime_id" "$architecture_directory" "$project_root/LICENSE" "$project_path" "$nuget_packages" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import sys
from xml.etree import ElementTree

def fail(message):
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)

state_directory = Path(sys.argv[1])
runtime_id = sys.argv[2]
output_directory = Path(sys.argv[3])
mackvm_license = Path(sys.argv[4])
expected_project_path = Path(sys.argv[5])
nuget_package_root = Path(sys.argv[6])
runtime_package_id = f"Microsoft.NETCore.App.Runtime.{runtime_id}"
runtimepack_id = f"runtimepack.{runtime_package_id}"
sdk_package_id = "Microsoft.Windows.SDK.NET.Ref"
sdk_runtimepack_id = f"runtimepack.{sdk_package_id}"

def valid_version(value, description):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9._+-]+", value):
        fail(f"The {description} version is invalid: {value!r}")
    return value

def read_json(path, description):
    if path.is_symlink() or not path.is_file():
        fail(f"The generated {description} is missing or unsafe: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"Could not read generated {description} at {path}: {error}")

def package_directory(package_id, version):
    if nuget_package_root.is_symlink() or not nuget_package_root.is_dir():
        fail(f"The NuGet global-packages directory is missing or unsafe: {nuget_package_root}")
    package_id_directory = nuget_package_root / package_id.lower()
    candidate = package_id_directory / version.lower()
    if package_id_directory.is_symlink() or candidate.is_symlink() or not candidate.is_dir():
        fail(f"Could not find the exact {package_id}/{version} package in the NuGet global-packages directory {nuget_package_root}.")
    root_resolved = nuget_package_root.resolve()
    candidate_resolved = candidate.resolve()
    try:
        candidate_resolved.relative_to(root_resolved)
    except ValueError:
        fail(f"The resolved {package_id}/{version} package escapes the NuGet global-packages directory: {candidate}")
    return candidate

if state_directory.is_symlink() or not state_directory.is_dir():
    fail(f"Generated build state was not found while resolving {runtime_package_id}: {state_directory}")
app_bin_directory = state_directory / "bin"
if app_bin_directory.is_symlink() or not app_bin_directory.is_dir():
    fail(f"Could not find the generated app bin directory: {app_bin_directory}")
app_bin_root = app_bin_directory / expected_project_path.stem
if app_bin_root.is_symlink() or not app_bin_root.is_dir():
    fail(f"Could not find the app publish metadata directory for {expected_project_path}: {app_bin_root}")

deps_files = []
for current, directories, files in os.walk(app_bin_root, followlinks=False):
    directories[:] = [name for name in directories if not (Path(current) / name).is_symlink()]
    deps_files.extend(Path(current) / name for name in files if name.endswith(".deps.json"))
if len(deps_files) != 1:
    fail(f"Expected exactly one generated app .deps.json under {app_bin_root}; found {len(deps_files)}.")

deps_path = deps_files[0]
runtimeconfig_path = deps_path.with_name(deps_path.name[:-len(".deps.json")] + ".runtimeconfig.json")
deps = read_json(deps_path, "app .deps.json")
runtimeconfig = read_json(runtimeconfig_path, "app .runtimeconfig.json")
if not isinstance(deps, dict) or not isinstance(runtimeconfig, dict):
    fail(f"The app .deps.json or .runtimeconfig.json has an invalid top-level structure: {deps_path}")
runtime_target = deps.get("runtimeTarget")
runtime_target_name = runtime_target.get("name") if isinstance(runtime_target, dict) else None
targets = deps.get("targets")
libraries = deps.get("libraries")
if not isinstance(runtime_target_name, str) or not runtime_target_name.endswith("/" + runtime_id):
    fail(f"The app .deps.json does not select the requested runtime identifier {runtime_id}: {runtime_target_name!r}")
if not isinstance(targets, dict) or runtime_target_name not in targets:
    fail(f"The selected publish target is missing from {deps_path}: {runtime_target_name}")
if not isinstance(libraries, dict):
    fail(f"The app .deps.json has no libraries map: {deps_path}")
target_entries = targets[runtime_target_name]
if not isinstance(target_entries, dict):
    fail(f"The selected publish target is malformed in {deps_path}: {runtime_target_name}")

runtime_options = runtimeconfig.get("runtimeOptions")
if not isinstance(runtime_options, dict):
    fail(f"The self-contained app runtimeconfig has no runtimeOptions object: {runtimeconfig_path}")
frameworks = runtime_options.get("includedFrameworks")
if not isinstance(frameworks, list):
    fail(f"The self-contained app runtimeconfig has no includedFrameworks array: {runtimeconfig_path}")
core_frameworks = [
    item for item in frameworks
    if isinstance(item, dict)
    and isinstance(item.get("name"), str)
    and item["name"].casefold() == "microsoft.netcore.app"
]
if len(core_frameworks) != 1:
    fail(f"Expected exactly one Microsoft.NETCore.App entry in {runtimeconfig_path}; found {len(core_frameworks)}.")
core_version = valid_version(core_frameworks[0].get("version"), "Microsoft.NETCore.App framework")

app_targets = []
for target_key, target_value in target_entries.items():
    library_entries = [value for key, value in libraries.items() if key.casefold() == target_key.casefold()]
    dependencies = target_value.get("dependencies") if isinstance(target_value, dict) else None
    core_dependencies = [
        value for key, value in dependencies.items()
        if key.casefold() == runtimepack_id.casefold()
    ] if isinstance(dependencies, dict) else []
    if len(library_entries) == 1 and isinstance(library_entries[0], dict) and library_entries[0].get("type") == "project" and core_dependencies:
        app_targets.append((target_key, dependencies, core_dependencies))
if len(app_targets) != 1:
    fail(f"Expected exactly one app target depending on {runtimepack_id} in {deps_path}; found {len(app_targets)}.")

app_target_key, app_dependencies, core_dependencies = app_targets[0]
if len(core_dependencies) != 1:
    fail(f"Expected exactly one {runtimepack_id} dependency in app target {app_target_key}; found {len(core_dependencies)}.")
if valid_version(core_dependencies[0], runtimepack_id) != core_version:
    fail(f"The app .deps.json {runtimepack_id} version does not match the self-contained runtimeconfig version {core_version}.")

def require_runtimepack(package_id, version, target_map, library_map, deps_path):
    key = f"{package_id}/{version}"
    target_matches = [value for candidate, value in target_map.items() if candidate.casefold() == key.casefold()]
    library_matches = [value for candidate, value in library_map.items() if candidate.casefold() == key.casefold()]
    if len(target_matches) != 1 or len(library_matches) != 1:
        fail(f"Expected exactly one {key} runtimepack entry in the selected app target and libraries of {deps_path}.")
    if not isinstance(library_matches[0], dict) or library_matches[0].get("type") != "runtimepack":
        fail(f"The resolved {key} entry in {deps_path} is not a runtimepack.")
    if not isinstance(target_matches[0], dict):
        fail(f"The resolved {key} target entry is malformed in {deps_path}.")
    return target_matches[0]

runtime_target_entry = require_runtimepack(runtimepack_id, core_version, target_entries, libraries, deps_path)
if not isinstance(runtime_target_entry.get("runtime"), dict):
    fail(f"The resolved {runtimepack_id}/{core_version} has no runtime assets in {deps_path}.")
runtime_package_directory = package_directory(runtime_package_id, core_version)

if not output_directory.is_dir() or output_directory.is_symlink():
    fail(f"The architecture output directory is missing or unsafe: {output_directory}")
if not mackvm_license.is_file() or mackvm_license.is_symlink():
    fail(f"MacKVM's root MIT license was not found as a regular file: {mackvm_license}")

staged_assets = []
for asset_name in ("LICENSE.TXT", "THIRD-PARTY-NOTICES.TXT"):
    source = runtime_package_directory / asset_name
    if not source.is_file() or source.is_symlink():
        fail(
            f"Required .NET runtime legal asset is missing or unsafe: {source} "
            f"(resolved from {runtime_package_id}/{core_version}; app deps: {deps_path})."
        )
    destination_name = f"dotnet-{runtime_package_id}-{core_version}-{asset_name}"
    staged_assets.append((source, output_directory / destination_name))

sdk_reference_notice = None
sdk_package_id = "Microsoft.Windows.SDK.NET.Ref"
sdk_package_dependency = [
    value for key, value in app_dependencies.items()
    if key.casefold() == sdk_runtimepack_id.casefold()
]
if len(sdk_package_dependency) > 1:
    fail(f"Expected at most one {sdk_runtimepack_id} dependency in app target {app_target_key}; found {len(sdk_package_dependency)}.")
if sdk_package_dependency:
    sdk_version = valid_version(sdk_package_dependency[0], sdk_runtimepack_id)
    sdk_target_entry = require_runtimepack(sdk_runtimepack_id, sdk_version, target_entries, libraries, deps_path)
    sdk_runtime_assets = sdk_target_entry.get("runtime")
    if not isinstance(sdk_runtime_assets, dict) or not sdk_runtime_assets:
        fail(f"The resolved {sdk_runtimepack_id}/{sdk_version} has no runtime assembly entries in {deps_path}.")
    sdk_assemblies = []
    for assembly_path in sdk_runtime_assets:
        if not isinstance(assembly_path, str) or Path(assembly_path).name != assembly_path or not assembly_path.lower().endswith(".dll"):
            fail(f"Unsafe or unexpected Windows SDK runtime assembly entry in {deps_path}: {assembly_path!r}")
        sdk_assemblies.append(assembly_path)
    sdk_directory = package_directory(sdk_package_id, sdk_version)
    matching_nuspecs = []
    for nuspec_path in sdk_directory.glob("*.nuspec"):
        if nuspec_path.is_symlink() or not nuspec_path.is_file():
            fail(f"Refusing an unsafe Windows SDK package specification: {nuspec_path}")
        try:
            nuspec = ElementTree.parse(nuspec_path).getroot()
        except (OSError, ElementTree.ParseError) as error:
            fail(f"Could not read resolved Windows SDK package metadata at {nuspec_path}: {error}")
        package_id_nodes = [node for node in nuspec.iter() if node.tag.rsplit("}", 1)[-1].lower() == "id"]
        package_ids = [(node.text or "").strip() for node in package_id_nodes]
        if sdk_package_id in package_ids:
            license_urls = [
                (node.text or "").strip()
                for node in nuspec.iter()
                if node.tag.rsplit("}", 1)[-1].lower() == "licenseurl"
            ]
            if len(license_urls) != 1 or not license_urls[0].startswith("https://"):
                fail(f"The resolved {sdk_package_id}/{sdk_version} package metadata has no HTTPS licenseUrl: {nuspec_path}")
            matching_nuspecs.append(license_urls[0])
    if len(matching_nuspecs) != 1:
        fail(f"Expected exactly one {sdk_package_id} NuGet specification in {sdk_directory}; found {len(matching_nuspecs)}.")
    sdk_reference_notice = (
        "Windows SDK .NET runtime assemblies included by this publish.\n"
        f"Resolved package: {sdk_package_id} {sdk_version}\n"
        f"Included assemblies: {', '.join(sorted(sdk_assemblies, key=str.casefold))}\n"
        f"License and terms: {matching_nuspecs[0]}\n"
    )

license_destination = output_directory / "MacKVM-LICENSE.txt"
dotnet_license_destination = output_directory / "DOTNET-LIBRARY-LICENSE.txt"
if not dotnet_license_destination.parent.is_dir():
    fail(f"The legal notice destination directory is missing: {dotnet_license_destination.parent}")
planned_destinations = [destination for _source, destination in staged_assets] + [license_destination, dotnet_license_destination]
if sdk_reference_notice is not None:
    planned_destinations.append(output_directory / "WINDOWS-SDK-REFERENCE.txt")
for destination in planned_destinations:
    if destination.exists() or destination.is_symlink():
        fail(f"Refusing to overwrite an existing legal notice destination: {destination}")

for source, destination in staged_assets:
    shutil.copyfile(source, destination)
shutil.copyfile(mackvm_license, license_destination)
dotnet_license_destination.write_text(
    "Microsoft identifies CoreCLR and .NET runtimes included in Windows single-file applications as governed by the .NET Library License.\n"
    "Full terms: https://dotnet.microsoft.com/en-us/dotnet_library_license.htm\n"
    "Windows .NET licensing information: https://github.com/dotnet/core/blob/main/license-information-windows.md\n"
    "This file is a reference pointer, not a copy or substitute for Microsoft's complete license terms.\n",
    encoding="utf-8",
)
if sdk_reference_notice is not None:
    (output_directory / "WINDOWS-SDK-REFERENCE.txt").write_text(sdk_reference_notice, encoding="utf-8")
print(f"Staged exact runtime notices from {runtime_package_id}/{core_version} beside the executable.")
PY
  then
    :
  else
    local status=$?
    fail "Could not stage resolved .NET runtime notices for $runtime_id (exit code $status)."
  fi
}

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

  stage_resolved_runtime_notices "$state_directory" "$runtime_id" "$architecture_directory" "$project_path"

  echo "Published $executable ($label; $file_description)"
done
