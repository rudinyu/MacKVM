#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_root"

source "$project_root/scripts/lib/build-environment.sh"

if [[ $# -gt 0 ]]; then
  if [[ "$#" -eq 1 && "$1" == "--help" ]]; then
    echo "Usage: scripts/clean-artifacts.sh"
    echo "Deletes generated files under dist/. Use this only when those artifacts are no longer needed."
    exit 0
  fi
  echo "Usage: scripts/clean-artifacts.sh" >&2
  exit 2
fi

mackvm_enter_build_lock "$project_root" "$project_root/scripts/clean-artifacts.sh"

if [[ -z "$project_root" || "$project_root" == "/" ]]; then
  echo "Refusing to clean artifacts from an empty or root project path." >&2
  exit 1
fi

dist_root="$project_root/dist"
case "$dist_root" in
  "$project_root/dist") ;;
  *)
    echo "Refusing to clean unexpected artifact path: $dist_root" >&2
    exit 1
    ;;
esac

if [[ -e "$dist_root" || -L "$dist_root" ]]; then
  rm -rf -- "$dist_root"
fi
echo "Deleted generated artifacts under dist/."
