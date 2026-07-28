#!/usr/bin/env bash
set -euo pipefail

# Run this once after every step in the complete plan is finished.
codex-precommit-check CODEX_CLAUDE_REVIEW.md
