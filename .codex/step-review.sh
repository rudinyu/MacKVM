#!/usr/bin/env bash
set -euo pipefail

# Run this once after one complete plan step and its tests are complete.
./.codex/ci.sh
codex review --uncommitted | tee CODEX_REVIEW.md

if [[ ! -s CODEX_REVIEW.md ]]; then
  echo "Codex review produced no report." >&2
  exit 1
fi
