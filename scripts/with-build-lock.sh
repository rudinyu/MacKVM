#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_root/scripts/lib/build-environment.sh"

if [[ $# -eq 1 && "$1" == "--help" ]]; then
  echo "Usage: scripts/with-build-lock.sh COMMAND [ARG ...]" >&2
  echo "Runs one build or cleanup command while holding the repository build lock." >&2
  exit 0
fi
if [[ $# -lt 1 ]]; then
  echo "Usage: scripts/with-build-lock.sh COMMAND [ARG ...]" >&2
  exit 2
fi

if mackvm_build_lock_is_held "$project_root"; then
  exec "$@"
fi
if mackvm_lock_environment_is_set; then
  echo "MacKVM build lock environment does not match $project_root." >&2
  exit 1
fi

lock_dir="$project_root/.mackvm-build.lock"
wait_limit="${MACKVM_BUILD_LOCK_WAIT_SECONDS:-300}"
if [[ ! "$wait_limit" =~ ^[1-9][0-9]*$ ]]; then
  echo "MACKVM_BUILD_LOCK_WAIT_SECONDS must be a positive integer." >&2
  exit 2
fi
waited_seconds=0
while ! mkdir "$lock_dir" 2>/dev/null; do
  if [[ -L "$lock_dir" ]]; then
    echo "Refusing to use a symlink as the MacKVM build lock: $lock_dir" >&2
    exit 1
  fi
  if [[ ! -d "$lock_dir" ]]; then
    echo "Could not create the MacKVM build lock at $lock_dir; the path is unavailable or not writable." >&2
    exit 1
  fi
  if [[ "$waited_seconds" -eq 0 ]]; then
    echo "Waiting for the MacKVM build lock at $lock_dir."
  elif [[ $((waited_seconds % 30)) -eq 0 ]]; then
    echo "Still waiting for the MacKVM build lock at $lock_dir."
  fi
  if [[ "$waited_seconds" -ge "$wait_limit" ]]; then
    owner_pid="unknown"
    if [[ -r "$lock_dir/owner" ]]; then
      IFS=' ' read -r owner_pid _ < "$lock_dir/owner" || owner_pid="unknown"
    fi
    echo "Timed out waiting for the MacKVM build lock (owner PID: $owner_pid). Inspect $lock_dir before removing a stale lock." >&2
    exit 75
  fi
  sleep 1
  waited_seconds=$((waited_seconds + 1))
done

lock_token="$$-${RANDOM}-${RANDOM}-$(date +%s)"
if ! printf '%s %s\n' "$$" "$lock_token" > "$lock_dir/owner"; then
  rmdir "$lock_dir" 2>/dev/null || true
  echo "Could not write the MacKVM build lock owner file." >&2
  exit 1
fi

export MACKVM_BUILD_LOCK_DIR="$lock_dir"
export MACKVM_BUILD_LOCK_TOKEN="$lock_token"

release_build_lock() {
  if mackvm_build_lock_is_held "$project_root"; then
    rm -f -- "$lock_dir/owner"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
}
trap release_build_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$@"
