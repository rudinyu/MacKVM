#!/bin/bash
set -euo pipefail

dmg_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec /bin/bash "$dmg_dir/scripts/uninstall-app.sh" "$@"
