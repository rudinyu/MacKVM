# Shared helpers for MacKVM build entrypoints. Source from Bash scripts.

mackvm_lock_environment_is_set() {
  [[ -n "${MACKVM_BUILD_LOCK_DIR:-}" || -n "${MACKVM_BUILD_LOCK_TOKEN:-}" ]]
}

mackvm_build_lock_is_held() {
  local project_root="$1"
  local lock_dir="$project_root/.mackvm-build.lock"
  local owner_pid=""
  local owner_token=""
  local extra=""

  [[ "${MACKVM_BUILD_LOCK_DIR:-}" == "$lock_dir" && \
     -n "${MACKVM_BUILD_LOCK_TOKEN:-}" && \
     -d "$lock_dir" && ! -L "$lock_dir" && \
     -f "$lock_dir/owner" ]] || return 1

  IFS=' ' read -r owner_pid owner_token extra < "$lock_dir/owner" || return 1
  [[ "$owner_pid" =~ ^[0-9]+$ && \
     -n "$owner_token" && \
     -z "$extra" && \
     "$owner_token" == "$MACKVM_BUILD_LOCK_TOKEN" ]]
}

mackvm_enter_build_lock() {
  local project_root="$1"
  local script_path="$2"
  shift 2

  if mackvm_build_lock_is_held "$project_root"; then
    return 0
  fi
  if mackvm_lock_environment_is_set; then
    echo "MacKVM build lock environment does not match $project_root." >&2
    return 1
  fi

  exec "$project_root/scripts/with-build-lock.sh" "$script_path" "$@"
}

mackvm_validate_full_xcode() {
  local candidate="$1"
  local normalized=""
  local version_output=""
  local swift_path=""
  local swift_version=""
  local clang_path=""
  local sdk_path=""

  [[ "$candidate" == /* ]] || return 1
  if [[ -d "$candidate/Contents/Developer" ]]; then
    candidate="$candidate/Contents/Developer"
  fi
  [[ -d "$candidate" && \
     -x "$candidate/usr/bin/xcodebuild" && \
     -d "$candidate/Platforms/MacOSX.platform" ]] || return 1

  normalized="$(cd -P -- "$candidate" && pwd -P)" || return 1
  version_output="$("$normalized/usr/bin/xcodebuild" -version 2>/dev/null)" || return 1
  [[ "$version_output" == Xcode\ * ]] || return 1
  command -v xcrun >/dev/null 2>&1 || return 1
  swift_path="$(DEVELOPER_DIR="$normalized" xcrun --find swift 2>/dev/null)" || return 1
  [[ -x "$swift_path" ]] || return 1
  swift_version="$("$swift_path" --version 2>/dev/null)" || return 1
  [[ "$swift_version" == Apple\ Swift\ version\ * ]] || return 1
  clang_path="$(DEVELOPER_DIR="$normalized" xcrun --find clang 2>/dev/null)" || return 1
  [[ -x "$clang_path" ]] || return 1
  sdk_path="$(DEVELOPER_DIR="$normalized" xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || return 1
  [[ -d "$sdk_path" ]] || return 1

  MACKVM_VALIDATED_DEVELOPER_DIR="$normalized"
  MACKVM_XCODE_VERSION="${version_output%%$'\n'*}"
  MACKVM_SWIFT_PATH="$swift_path"
  MACKVM_SWIFT_VERSION="${swift_version%%$'\n'*}"
  MACKVM_CLANG_PATH="$clang_path"
  MACKVM_MACOS_SDK_PATH="$sdk_path"
}

mackvm_select_xcode() {
  local candidate=""

  if [[ "${DEVELOPER_DIR+x}" ]]; then
    if ! mackvm_validate_full_xcode "$DEVELOPER_DIR"; then
      echo "DEVELOPER_DIR is set but does not point to a usable full Xcode installation: ${DEVELOPER_DIR:-<empty>}" >&2
      return 2
    fi
    export DEVELOPER_DIR="$MACKVM_VALIDATED_DEVELOPER_DIR"
    return 0
  fi

  if command -v xcode-select >/dev/null 2>&1; then
    candidate="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "$candidate" ]] && mackvm_validate_full_xcode "$candidate"; then
      export DEVELOPER_DIR="$MACKVM_VALIDATED_DEVELOPER_DIR"
      return 0
    fi
  fi

  for candidate in \
    /Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode*.app/Contents/Developer; do
    [[ -d "$candidate" ]] || continue
    if mackvm_validate_full_xcode "$candidate"; then
      export DEVELOPER_DIR="$MACKVM_VALIDATED_DEVELOPER_DIR"
      return 0
    fi
  done

  if [[ -n "${HOME:-}" ]]; then
    for candidate in "$HOME"/Applications/Xcode*.app/Contents/Developer; do
      [[ -d "$candidate" ]] || continue
      if mackvm_validate_full_xcode "$candidate"; then
        export DEVELOPER_DIR="$MACKVM_VALIDATED_DEVELOPER_DIR"
        return 0
      fi
    done
  fi

  echo "A full Xcode installation was not found. Install Xcode or set DEVELOPER_DIR to its Contents/Developer directory." >&2
  return 1
}
