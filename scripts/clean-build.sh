#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

# This helper is intentionally scoped to generated paths owned by this
# repository. Keep the guards explicit: a malformed project root must never
# turn a clean build into a broad filesystem deletion.
if [[ -z "$project_root" || "$project_root" == "/" ]]; then
  echo "Refusing to clean an empty or root project path." >&2
  exit 1
fi

dist_root="$project_root/dist"
build_root="$project_root/.build"

for generated_root in "$build_root" "$dist_root"; do
  case "$generated_root" in
    "$project_root/.build"|"$project_root/dist")
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

mkdir -p "$dist_root"
echo "Cleaned Swift build state and dist outputs."
