#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_root"

source "$project_root/scripts/lib/build-environment.sh"

if [[ $# -gt 0 ]]; then
  if [[ "$#" -eq 1 && "$1" == "--help" ]]; then
    echo "Usage: scripts/clean-build.sh"
    echo "Removes project-local SwiftPM build state and preserves dist artifacts."
    exit 0
  fi
  echo "Usage: scripts/clean-build.sh" >&2
  exit 2
fi

mackvm_enter_build_lock "$project_root" "$project_root/scripts/clean-build.sh"

# This helper is intentionally scoped to generated paths owned by this
# repository. Keep the guards explicit: a malformed project root must never
# turn a clean build into a broad filesystem deletion.
if [[ -z "$project_root" || "$project_root" == "/" ]]; then
  echo "Refusing to clean an empty or root project path." >&2
  exit 1
fi

build_root="$project_root/.build"

for generated_root in "$build_root"; do
  case "$generated_root" in
    "$project_root/.build")
      ;;
    *)
      echo "Refusing to clean unexpected path: $generated_root" >&2
      exit 1
      ;;
  esac

  # `-L` also catches a dangling symlink; rm removes the link itself rather
  # than following it, so a user-created link cannot escape the repo root.
  if [[ -e "$generated_root" || -L "$generated_root" ]]; then
    rm -rf -- "$generated_root"
  fi
done

echo "Cleaned Swift build state; dist artifacts were preserved."
