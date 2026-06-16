#!/usr/bin/env bash
set -euo pipefail

umask 077

APP_NAME="${CODEX_APP_NAME:-Codex}"
SWITCHER_HOME="${SWITCHER_HOME:-$HOME/Library/Application Support/CodexAccountSwitcher}"
PROFILES_DIR="$SWITCHER_HOME/profiles"
ACTIVE_FILE="$SWITCHER_HOME/active-profile"
LOCK_DIR="$SWITCHER_HOME/.lock"

CODEX_AUTH_FILE="${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"
CODEX_APP_SUPPORT="${CODEX_APP_SUPPORT:-$HOME/Library/Application Support/Codex}"

usage() {
  cat <<'USAGE'
Codex Account Switcher

Usage:
  codex-account-switcher.sh capture <profile>
  codex-account-switcher.sh save-auth <profile>
  codex-account-switcher.sh switch <profile> [--no-open]
  codex-account-switcher.sh list [--plain]
  codex-account-switcher.sh active
  codex-account-switcher.sh delete <profile>
  codex-account-switcher.sh open-folder

Environment overrides:
  SWITCHER_HOME       Profile storage directory
  CODEX_AUTH_FILE     Codex CLI auth file, default ~/.codex/auth.json
  CODEX_APP_SUPPORT   Codex Desktop state directory, default ~/Library/Application Support/Codex
  CODEX_APP_NAME      macOS app name, default Codex
USAGE
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*" >&2
}

ensure_store() {
  mkdir -p "$PROFILES_DIR"
}

with_lock() {
  ensure_store
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "another switch is already running"
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

validate_profile_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "profile name is required"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail "profile name may only contain letters, numbers, dot, dash, and underscore"
}

profile_dir() {
  printf '%s/%s\n' "$PROFILES_DIR" "$1"
}

profile_auth_file() {
  printf '%s/auth/auth.json\n' "$(profile_dir "$1")"
}

profile_app_support_dir() {
  printf '%s/app-support/Codex\n' "$(profile_dir "$1")"
}

active_profile() {
  if [[ -f "$ACTIVE_FILE" ]]; then
    sed -n '1p' "$ACTIVE_FILE"
  fi
}

copy_file_if_present() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -f "$src" ]]; then
    cp -p "$src" "$dst"
    chmod 600 "$dst" 2>/dev/null || true
  else
    rm -f "$dst"
  fi
}

assert_safe_sync_target() {
  local dst="$1"
  case "$dst" in
    ""|"/"|"$HOME"|"$HOME/"|"$HOME/Library"|"$HOME/Library/Application Support")
      fail "refusing to sync into unsafe target: $dst"
      ;;
  esac
}

sync_dir_if_present() {
  local src="$1"
  local dst="$2"
  assert_safe_sync_target "$dst"

  if [[ -d "$src" && -d "$dst" ]]; then
    local src_real dst_real
    src_real="$(cd "$src" && pwd -P)"
    dst_real="$(cd "$dst" && pwd -P)"
    [[ "$src_real" != "$dst_real" ]] || fail "refusing to sync a directory onto itself: $src"
  fi

  mkdir -p "$(dirname "$dst")"
  if [[ ! -d "$src" ]]; then
    rm -rf "$dst"
    return 0
  fi

  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --checksum --delete \
      --exclude 'Cache/' \
      --exclude 'Code Cache/' \
      --exclude 'Crashpad/' \
      --exclude 'DawnGraphiteCache/' \
      --exclude 'DawnWebGPUCache/' \
      --exclude 'GPUCache/' \
      "$src"/ "$dst"/
  else
    local tmp="$dst.tmp.$$"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    cp -pR "$src"/. "$tmp"/
    rm -rf "$dst"
    mv "$tmp" "$dst"
  fi
}

capture_into_profile() {
  local name="$1"
  validate_profile_name "$name"
  ensure_store

  local dir
  dir="$(profile_dir "$name")"
  mkdir -p "$dir/auth" "$dir/app-support"

  copy_file_if_present "$CODEX_AUTH_FILE" "$(profile_auth_file "$name")"
  sync_dir_if_present "$CODEX_APP_SUPPORT" "$(profile_app_support_dir "$name")"

  {
    printf 'name=%s\n' "$name"
    printf 'captured_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'auth_file=%s\n' "$CODEX_AUTH_FILE"
    printf 'app_support=%s\n' "$CODEX_APP_SUPPORT"
  } > "$dir/profile.env"
}

save_auth_into_profile() {
  local name="$1"
  validate_profile_name "$name"
  ensure_store

  [[ -d "$(profile_dir "$name")" ]] || fail "profile '$name' does not exist"
  [[ -s "$CODEX_AUTH_FILE" ]] || fail "current Codex auth file is missing or empty"

  copy_file_if_present "$CODEX_AUTH_FILE" "$(profile_auth_file "$name")"
  {
    if [[ -f "$(profile_dir "$name")/profile.env" ]]; then
      grep -v '^auth_saved_at=' "$(profile_dir "$name")/profile.env" || true
    else
      printf 'name=%s\n' "$name"
    fi
    printf 'auth_saved_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$(profile_dir "$name")/profile.env.tmp"
  mv "$(profile_dir "$name")/profile.env.tmp" "$(profile_dir "$name")/profile.env"
}

cmd_capture() {
  local name="${1:-}"
  validate_profile_name "$name"
  with_lock
  log "quitting $APP_NAME before capture"
  quit_codex
  capture_into_profile "$name"
  printf '%s\n' "$name" > "$ACTIVE_FILE"
  log "captured current Codex state as '$name'"
}

cmd_save_auth() {
  local name="${1:-}"
  validate_profile_name "$name"
  with_lock
  save_auth_into_profile "$name"
  printf '%s\n' "$name" > "$ACTIVE_FILE"
  log "saved current Codex auth token into '$name'"
}

quit_codex() {
  /usr/bin/osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in {1..40}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  log "warning: $APP_NAME is still running; continuing anyway"
}

restore_profile() {
  local name="$1"
  local auth_src app_src
  auth_src="$(profile_auth_file "$name")"
  app_src="$(profile_app_support_dir "$name")"

  [[ -d "$(profile_dir "$name")" ]] || fail "profile '$name' does not exist"
  [[ -f "$auth_src" ]] || fail "profile '$name' has no auth.json; capture it after logging in"

  mkdir -p "$(dirname "$CODEX_AUTH_FILE")"
  cp -p "$auth_src" "$CODEX_AUTH_FILE"
  chmod 600 "$CODEX_AUTH_FILE" 2>/dev/null || true

  if [[ -d "$app_src" ]]; then
    sync_dir_if_present "$app_src" "$CODEX_APP_SUPPORT"
  else
    log "warning: profile '$name' has no Codex Desktop state; only auth.json was restored"
  fi
}

cmd_switch() {
  local name="${1:-}"
  local no_open="${2:-}"
  validate_profile_name "$name"
  [[ "$no_open" == "" || "$no_open" == "--no-open" ]] || fail "unknown option: $no_open"

  with_lock

  local current
  current="$(active_profile || true)"
  if [[ -z "$current" ]]; then
    fail "no active profile is recorded; run 'capture <profile>' for the current account first"
  fi
  validate_profile_name "$current"

  log "quitting $APP_NAME"
  quit_codex

  if [[ "$current" != "$name" ]]; then
    log "saving current Codex state into '$current'"
    capture_into_profile "$current"
  fi

  log "switching to '$name'"
  restore_profile "$name"
  printf '%s\n' "$name" > "$ACTIVE_FILE"

  if [[ "$no_open" != "--no-open" ]]; then
    log "opening $APP_NAME"
    /usr/bin/open -a "$APP_NAME" >/dev/null 2>&1 || log "warning: could not open $APP_NAME"
  fi
}

cmd_list() {
  local plain="${1:-}"
  [[ "$plain" == "" || "$plain" == "--plain" ]] || fail "unknown option: $plain"
  ensure_store
  local active
  active="$(active_profile || true)"

  find "$PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | while IFS= read -r dir; do
    local name
    name="$(basename "$dir")"
    if [[ "$plain" == "--plain" ]]; then
      printf '%s\n' "$name"
    elif [[ "$name" == "$active" ]]; then
      printf '* %s\n' "$name"
    else
      printf '  %s\n' "$name"
    fi
  done
}

cmd_active() {
  active_profile || true
}

cmd_delete() {
  local name="${1:-}"
  validate_profile_name "$name"
  with_lock

  local dir
  dir="$(profile_dir "$name")"
  [[ -d "$dir" ]] || fail "profile '$name' does not exist"

  local active
  active="$(active_profile || true)"
  if [[ "$active" == "$name" ]]; then
    fail "cannot delete the active profile; switch to another profile first"
  fi

  rm -rf "$dir"
  log "deleted profile '$name'"
}

cmd_open_folder() {
  ensure_store
  /usr/bin/open "$SWITCHER_HOME"
}

main() {
  local command="${1:-}"
  shift || true

  case "$command" in
    capture) cmd_capture "$@" ;;
    save-auth) cmd_save_auth "$@" ;;
    switch) cmd_switch "$@" ;;
    list) cmd_list "$@" ;;
    active) cmd_active ;;
    delete) cmd_delete "$@" ;;
    open-folder) cmd_open_folder ;;
    -h|--help|help|"") usage ;;
    *) fail "unknown command: $command" ;;
  esac
}

main "$@"
