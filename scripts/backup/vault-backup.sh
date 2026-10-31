#!/bin/bash
# Versioned Mac-side backup of the Notetaker vault to Backblaze B2 via restic.
# Usage: vault-backup.sh [run|check|snapshots|restore-test]
# See scripts/backup/README.md. Secrets come from the macOS Keychain only and
# are exported solely into the restic child process; nothing here echoes them.
set -euo pipefail

VAULT_ROOT="${VAULT_ROOT:-$HOME/Library/Mobile Documents/iCloud~com~rchaight~notetaker/Documents}"
LOG="${VAULT_BACKUP_LOG:-$HOME/Library/Logs/notetaker-backup.log}"
MIN_FILES="${VAULT_MIN_FILES:-100}"
BACKUP_HOST="notetaker-mac"
BACKUP_TAG="notetaker-vault"
KC_ACCOUNT="${USER:-$(id -un)}"
LOG_MAX_BYTES=1048576
LOG_KEEP_LINES=2000

# Keep in sync with the diff -x list in restore_test.
EXCLUDES=("_index.md" ".DS_Store" "*.icloud" ".Trash")

LOCAL_MODE=0
KC_ID="" KC_KEY="" KC_PW="" KC_BUCKET=""

log() {
  mkdir -p "$(dirname "$LOG")"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"
  printf '%s\n' "$*" >&2
}

notify() {
  if [ "${VAULT_BACKUP_NO_NOTIFY:-0}" = 1 ]; then return 0; fi
  local msg="${1//\"/\'}"
  osascript -e "display notification \"$msg\" with title \"Notetaker backup\"" >/dev/null 2>&1 || true
}

fail() {
  log "ERROR: $1"
  notify "$1"
  exit 1
}

rotate_log() {
  [ -f "$LOG" ] || return 0
  local size
  size=$(wc -c <"$LOG" | tr -d ' ')
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    tail -n "$LOG_KEEP_LINES" "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

# Print one Keychain secret on stdout; stderr suppressed so nothing leaks.
kc_get() {
  security find-generic-password -s "$1" -a "$KC_ACCOUNT" -w 2>/dev/null
}

kc_require() {
  local service="$1" val
  if ! val=$(kc_get "$service") || [ -z "$val" ]; then
    fail "Missing Keychain item '$service' (account $KC_ACCOUNT). See scripts/backup/README.md."
  fi
  printf '%s' "$val"
}

load_secrets() {
  # Test hook: a local (non-b2) repository plus the dry-run flag skips Keychain.
  if [ "${VAULT_BACKUP_DRY_RUN:-0}" = 1 ] && [ -n "${RESTIC_REPOSITORY:-}" ]; then
    case "$RESTIC_REPOSITORY" in
      b2:*) ;;
      *) LOCAL_MODE=1; return 0 ;;
    esac
  fi
  KC_ID=$(kc_require notetaker-backup-b2-key-id)
  KC_KEY=$(kc_require notetaker-backup-b2-key)
  KC_PW=$(kc_require notetaker-backup-restic-password)
  KC_BUCKET=$(kc_require notetaker-backup-b2-bucket)
}

# Run restic with credentials in the child environment only (never argv).
restic_cmd() {
  (
    if [ "$LOCAL_MODE" != 1 ]; then
      export B2_ACCOUNT_ID="$KC_ID" B2_ACCOUNT_KEY="$KC_KEY" RESTIC_PASSWORD="$KC_PW"
      export RESTIC_REPOSITORY="b2:${KC_BUCKET}:vault"
    fi
    exec restic "$@"
  )
}

count_files() {
  # `|| true`: under pipefail an unreadable directory (e.g. a macOS privacy denial in the launchd context) must reach the
  # file-count guard and its notification, not kill the script silently before `fail` runs.
  { find "$VAULT_ROOT" \( -name '_index.md' -o -name '.DS_Store' -o -name '*.icloud' -o -name '.Trash' \) -prune -o -type f -print 2>/dev/null || true; } | wc -l | tr -d ' '
}

# One run at a time: a mkdir lock with a pid file; a lock left by a dead process is taken over.
LOCKDIR="${VAULT_BACKUP_LOCKDIR:-$HOME/Library/Caches/notetaker-backup.lock}"
acquire_lock() {
  mkdir -p "$(dirname "$LOCKDIR")"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    local other
    other=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
      fail "Another backup run is in progress (pid $other)."
    fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" || fail "Could not take the backup lock at $LOCKDIR."
  fi
  echo $$ >"$LOCKDIR/pid"
  trap 'rm -rf "$LOCKDIR"' EXIT
}

guard_vault() {
  [ -d "$VAULT_ROOT" ] || fail "Vault folder not found (iCloud not mounted?). Backup aborted."
  local n
  n=$(count_files)
  if [ "$n" -lt "$MIN_FILES" ]; then
    fail "Vault has only $n files (need $MIN_FILES). iCloud not ready? Backup aborted."
  fi
  log "Vault OK: $n files"
}

preflight() {
  command -v restic >/dev/null 2>&1 || fail "restic not found in PATH (brew install restic)."
  load_secrets
}

cmd_run() {
  preflight
  acquire_lock
  guard_vault
  local args=() p rc=0
  # No --no-lock: `restic backup` always takes a shared lock (the flag is ignored there). With the append-only key the
  # B2 backend removes the lock by hiding the object, which needs only writeFiles.
  args+=(backup --host "$BACKUP_HOST" --tag "$BACKUP_TAG")
  for p in "${EXCLUDES[@]}"; do args+=(--exclude "$p"); done
  if [ "${VAULT_BACKUP_DRY_RUN:-0}" = 1 ]; then args+=(--dry-run --verbose=2); fi
  args+=("$VAULT_ROOT")
  log "Backup starting"
  restic_cmd "${args[@]}" >>"$LOG" 2>&1 || rc=$?
  if [ "$rc" -eq 3 ]; then
    # restic exit 3: a snapshot WAS created but some source files could not be read (e.g. an iCloud file that is not
    # downloaded while offline). Not a clean success, not a lost backup.
    log "Backup finished with unreadable files (exit 3). See $LOG."
    notify "Backup finished, but some files could not be read."
    exit 3
  elif [ "$rc" -ne 0 ]; then
    fail "restic backup failed (exit $rc). See $LOG."
  fi
  log "Backup finished OK"
}

cmd_check() {
  preflight
  log "Check starting (5% data subset)"
  local rc=0
  restic_cmd check --no-lock --read-data-subset=5% >>"$LOG" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "restic check failed (exit $rc). See $LOG."
  log "Check OK"
}

cmd_snapshots() {
  preflight
  restic_cmd snapshots --no-lock --host "$BACKUP_HOST" --tag "$BACKUP_TAG"
}

cmd_restore_test() {
  preflight
  acquire_lock
  guard_vault
  local tmp rc=0 p dargs=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/notetaker-restore.XXXXXX")
  # shellcheck disable=SC2064
  # restic restores the source's directory modes, including read-only ones, which would make rm fail: chmod first.
  trap "chmod -R u+w '$tmp' 2>/dev/null; rm -rf '$tmp'; rm -rf '$LOCKDIR'" EXIT
  log "Restore test into temp dir"
  restic_cmd restore latest --no-lock --host "$BACKUP_HOST" --tag "$BACKUP_TAG" --target "$tmp" >>"$LOG" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "restore-test: restic restore failed (exit $rc). See $LOG."
  fi
  for p in "${EXCLUDES[@]}"; do dargs+=(-x "$p"); done
  # restic recreates the absolute source path under the target directory.
  if diff -rq "${dargs[@]}" "$VAULT_ROOT" "$tmp$VAULT_ROOT" >>"$LOG" 2>&1; then
    log "restore-test PASS"
    echo "PASS: latest snapshot matches the vault"
  else
    log "restore-test FAIL (see diff above)"
    notify "Restore test FAILED"
    echo "FAIL: restored snapshot differs from the vault (edits since backup also cause this; see $LOG)"
    exit 1
  fi
}

usage() {
  echo "Usage: ${0##*/} [run|check|snapshots|restore-test]" >&2
  exit 2
}

main() {
  local cmd="${1:-run}"
  case "$cmd" in
    run|check|snapshots|restore-test) ;;
    *) usage ;;
  esac
  rotate_log
  case "$cmd" in
    run) cmd_run ;;
    check) cmd_check ;;
    snapshots) cmd_snapshots ;;
    restore-test) cmd_restore_test ;;
  esac
}

main "$@"
