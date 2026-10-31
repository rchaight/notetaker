#!/usr/bin/env bash
# run-local.sh — local test harness for vault-restic-backup (spec 4.9).
#   bash test/run-local.sh [--scratch DIR]
# Needs bash, python3, restic on PATH. Uses a throwaway local restic repo, a
# generated fixture and a test env file (mode 0400). Never touches B2, the
# network or the repo tree; scratch defaults to a fresh dir under $TMPDIR.
# Prints one PASS/FAIL line per case; exits non-zero on any FAIL.
# shellcheck disable=SC1091,SC2015  # test env files are sourced at run time; pass() never fails, so A && pass || fail is safe
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="$HERE/../ct/vault-restic-backup"
MCHECK="$HERE/../ct/manifest-check.py"
FIX="$HERE/make-fixture.py"
SCRATCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch) SCRATCH="${2:?--scratch needs a dir}"; shift ;;
    *) echo "usage: run-local.sh [--scratch DIR]" >&2; exit 64 ;;
  esac
  shift
done
command -v restic > /dev/null || { echo "restic not on PATH" >&2; exit 1; }
PARENT="${SCRATCH:-${TMPDIR:-/tmp}}"
chk="$PARENT"
while [[ ! -d "$chk" ]]; do chk="$(dirname "$chk")"; done
case "$(cd "$chk" && pwd -P)/" in
  "$(cd "$HERE/../../.." && pwd -P)"/*) echo "scratch must be outside the repo" >&2; exit 1 ;;
esac
mkdir -p "$PARENT"
# Always work in a fresh subdir and remove only that, never the caller-supplied dir.
SCRATCH="$(mktemp -d "$PARENT/vault-backup-test.XXXXXX")"
SCRATCH="$(cd "$SCRATCH" && pwd)"
trap 'chmod -R u+w "$SCRATCH" 2> /dev/null || true; rm -rf "$SCRATCH"' EXIT

FAILS=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1  ($2)"; FAILS=$((FAILS + 1)); }
# expect <name> <got> <want>
expect() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "got '$2', want '$3'"; fi; }

# --- per-scenario world: fresh inbox, state, log, repo -----------------------------
W=""
new_world() {
  W="$SCRATCH/w$1"
  rm -rf "$W"; mkdir -p "$W/state" "$W/cache"
  export VAULT_BACKUP_ENV="$W/env" VAULT_BACKUP_SOURCE="$W/inbox" VAULT_BACKUP_STATE="$W/state"
  export VAULT_BACKUP_LOG="$W/backup.log" VAULT_BACKUP_CACHE="$W/cache" VAULT_BACKUP_ALLOW_DISK_TMP=1
  unset VAULT_BACKUP_NOW VAULT_MIN_NOTES || true
  printf 'RESTIC_REPOSITORY=%s\nRESTIC_PASSWORD=throwaway-test-password\nRESTIC_CACHE_DIR=%s\n' "$W/repo" "$W/cache" > "$W/env"
  chmod 0400 "$W/env"
  (set -a; . "$W/env"; set +a; restic init > /dev/null)
}
fixture() { python3 -I "$FIX" "$W/inbox" "$@"; }
wrap() { local rc=0; bash "$WRAP" "$@" > "$W/stdout" 2> "$W/stderr" || rc=$?; echo "$rc"; }
run_code() { cut -d' ' -f1 "$W/state/last-run"; }
run_msg() { cut -d' ' -f4 "$W/state/last-run"; }
nsnap() {
  (set -a; . "$W/env"; set +a; restic snapshots --json 2> /dev/null | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))')
}
rs() { (set -a; . "$W/env"; set +a; restic "$@"); }

# --- 1, 2, 11, 12, 15 share a world ---------------------------------------------------
new_world 1
fixture --notes 120
rc=$(wrap run)
expect "1  run 120 notes: exit 0" "$rc" 0
expect "1  run: last-run ok" "$(run_code)" ok
grep -q '^count=120 ' "$W/state/last-success" && pass "1  last-success count=120" || fail "1  last-success count=120" "$(cat "$W/state/last-success" 2> /dev/null)"
snap="$(rs snapshots --json | python3 -I -c 'import json,sys; s=json.load(sys.stdin)[0]; print(s["hostname"], ",".join(s["tags"]), ",".join(s["paths"]))')"
expect "1  snapshot host/tag/path" "$snap" "nr-replica notetaker-replica $W/inbox"
# stderr must be free of note paths and secrets
if grep -Eq 'note-[0-9]|throwaway' "$W/stderr"; then fail "1  stderr clean" "path or secret on stderr"; else pass "1  stderr has no note paths or secrets"; fi

rc=$(wrap run)
expect "2  second run: exit 0" "$rc" 0
# restic re-writes a few directory trees (dir metadata), so "0 B" never appears; dedup means
# no file is new/changed and only a few KiB are added (the first run added ~87 KiB).
last_files="$(grep -E '^Files: ' "$W/backup.log" | tail -1)"
last_added="$(grep 'Added to the repository' "$W/backup.log" | tail -1)"
if [[ "$last_files" =~ Files:\ +0\ new,\ +0\ changed ]] && [[ "$last_added" =~ repository:\ ([0-9.]+)\ (B|KiB) ]] \
  && { [[ "${BASH_REMATCH[2]}" == B ]] || [[ "${BASH_REMATCH[1]%%.*}" -lt 10 ]]; }; then
  pass "2  dedup: no new files, only tree metadata added"
else
  fail "2  dedup" "$last_files / $last_added"
fi

rc=$(wrap restore-test)
expect "11 restore-test exit 0" "$rc" 0
grep -q '^PASS' "$W/stdout" && pass "11 restore-test prints PASS" || fail "11 restore-test PASS" "$(cat "$W/stdout")"
[[ ! -e "$W/state/run/restore" ]] && pass "11 scratch dir removed" || fail "11 scratch dir removed" "still there"

# 15 (before case 12 touches nothing relevant): verify-last with moved clock
export VAULT_BACKUP_NOW
VAULT_BACKUP_NOW="$(python3 -I -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(hours=25)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
expect "15 verify-last at +25h" "$(wrap verify-last)" 0
VAULT_BACKUP_NOW="$(python3 -I -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(hours=27)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
expect "15 verify-last at +27h" "$(wrap verify-last)" 1
unset VAULT_BACKUP_NOW

# 12: modify one note after the last run
f="$(find "$W/inbox/vault" -name '*.md' | head -1)"
echo "edited" >> "$f"
rc=$(wrap restore-test)
expect "12 restore-test after edit: exit 1" "$rc" 1
grep -q '^FAIL' "$W/stdout" && pass "12 restore-test prints FAIL" || fail "12 prints FAIL" "$(cat "$W/stdout")"

# --- 3: DISABLED + disabled manifest ---------------------------------------------------
new_world 3
fixture --notes 120; wrap run > /dev/null
before=$(nsnap)
fixture --disabled
rc=$(wrap run)
expect "3  DISABLED+manifest: exit 4" "$rc" 4
expect "3  last-run skip disabled_marker" "$(run_code) $(run_msg)" "skip disabled_marker"
expect "3  snapshot count unchanged" "$(nsnap)" "$before"
grep -q '^count=120 ' "$W/state/last-success" && pass "3  last-success kept" || fail "3  last-success kept" "changed"

# --- 4: nr-kill image ------------------------------------------------------------------
fixture --kill-image
rc=$(wrap run)
expect "4  DISABLED only: exit 4" "$rc" 4
expect "4  last-run skip disabled_marker" "$(run_code) $(run_msg)" "skip disabled_marker"

# --- 5: manifest missing ---------------------------------------------------------------
fixture --notes 120; rm "$W/inbox/manifest.json"
rc=$(wrap run)
expect "5  manifest missing: exit 4" "$rc" 4
expect "5  last-run skip manifest_missing" "$(run_code) $(run_msg)" "skip manifest_missing"

# --- 6: six corruptions ----------------------------------------------------------------
for pair in digest:digest_mismatch size:entry_size sha:entry_sha256 stray:stray_file missing:entry_missing count:count_mismatch dup:bad_path vaultlink:not_regular; do
  kind="${pair%%:*}"; want="${pair##*:}"
  fixture --notes 120 --corrupt "$kind"
  rc=$(wrap run)
  expect "6  corrupt $kind: exit 4 / $want" "$rc $(run_code) $(run_msg)" "4 skip $want"
done
before=$(nsnap)
expect "6  no snapshot from corrupt runs" "$before" 1

# --- 7: below floor --------------------------------------------------------------------
new_world 7
fixture --notes 80
rc=$(wrap run)
expect "7  80 notes: exit 4 / below_floor" "$rc $(run_code) $(run_msg)" "4 skip below_floor"
expect "7  no snapshot" "$(nsnap)" 0

# --- 8: 25 % shrink ----------------------------------------------------------------------
# The spec's numbers (120 -> 90) sit under the 100 floor, which would trip first, so the
# shrunk runs lower the floor through the VAULT_MIN_NOTES hook; the 20 % rule is what is tested.
new_world 8
fixture --notes 120; wrap run > /dev/null
fixture --notes 90
export VAULT_MIN_NOTES=50
rc=$(wrap run)
expect "8  120 -> 90: exit 4 / shrink" "$rc $(run_code) $(run_msg)" "4 skip shrink"
rc=$(wrap accept-shrink); expect "8  accept-shrink exit 0" "$rc" 0
[[ -e "$W/state/accept-shrink" ]] && pass "8  accept-shrink file created" || fail "8  accept-shrink file created" "missing"
rc=$(wrap run)
expect "8  run after accept-shrink: exit 0 / ok" "$rc $(run_code)" "0 ok"
[[ ! -e "$W/state/accept-shrink" ]] && pass "8  accept-shrink consumed" || fail "8  accept-shrink consumed" "still there"
unset VAULT_MIN_NOTES

# --- 9: 16.7 % drop ----------------------------------------------------------------------
new_world 9
fixture --notes 120; wrap run > /dev/null
fixture --notes 100
rc=$(wrap run)
expect "9  120 -> 100: exit 0 / ok" "$rc $(run_code)" "0 ok"

# --- 10: stale replica -------------------------------------------------------------------
new_world 10
fixture --notes 120 --generated-at "$(python3 -I -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(days=8)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
rc=$(wrap run)
expect "10 stale: exit 0 / warn" "$rc $(run_code)" "0 warn"
expect "10 snapshot made" "$(nsnap)" 1
expect "15 verify-last after warn" "$(wrap verify-last)" 2

# --- 13: lock held -------------------------------------------------------------------------
new_world 13
fixture --notes 120
if command -v flock > /dev/null 2>&1; then
  flock "$W/state/lock" sleep 20 &
  holder=$!
else
  mkdir "$W/state/lock.d"
  sleep 20 &
  holder=$!
  echo "$holder" > "$W/state/lock.d/pid"
fi
sleep 1
rc=$(wrap run)
kill "$holder" 2> /dev/null || true; wait "$holder" 2> /dev/null || true
expect "13 lock held: exit 5" "$rc" 5
rm -rf "$W/state/lock.d"

# --- 14: placeholder env ---------------------------------------------------------------------
new_world 14
fixture --notes 120; wrap run > /dev/null
before=$(nsnap)
chmod u+w "$W/env"
printf 'RESTIC_REPOSITORY=%s\nRESTIC_PASSWORD=<PASSWORD>\n' "$W/repo" > "$W/env"
chmod 0400 "$W/env"
rc=$(wrap run)
expect "14 placeholder env: exit 1" "$rc" 1
lr_before="$(cat "$W/state/last-run")"
rc=$(wrap snapshots)
expect "14 snapshots with placeholder env: exit 1" "$rc" 1
expect "14 snapshots leaves last-run untouched" "$(cat "$W/state/last-run")" "$lr_before"
# nsnap needs a working env: restore a valid one to count
chmod u+w "$W/env"; printf 'RESTIC_REPOSITORY=%s\nRESTIC_PASSWORD=throwaway-test-password\n' "$W/repo" > "$W/env"; chmod 0400 "$W/env"
expect "14 repo snapshot count unchanged (no restic call)" "$(nsnap)" "$before"

# --- 16: manifest-check on 2000 notes ------------------------------------------------------------
new_world 16
fixture --notes 2000
start=$(date +%s)
if out=$(python3 -I "$MCHECK" "$W/inbox") && [[ "$out" == "ok count=2000 "* ]] && [[ $(($(date +%s) - start)) -lt 60 ]]; then
  pass "16 manifest-check 2000 notes under 60 s"
else
  fail "16 manifest-check 2000 notes" "${out:-no output}"
fi

# --- 17: concurrent push between restic and the post-check ------------------------------
new_world 17
fixture --notes 120; wrap run > /dev/null
ls_before="$(cat "$W/state/last-success")"
cat > "$W/hook.sh" << HOOK
#!/usr/bin/env bash
find "$W/inbox/vault" -name 'note-0001 *' -delete
HOOK
chmod +x "$W/hook.sh"
export VAULT_BACKUP_POSTCHECK_HOOK="$W/hook.sh"
rc=$(wrap run)
unset VAULT_BACKUP_POSTCHECK_HOOK
expect "17 concurrent push: exit 0 / warn concurrent_push" "$rc $(run_code) $(run_msg)" "0 warn concurrent_push"
expect "17 last-success unchanged" "$(cat "$W/state/last-success")" "$ls_before"
expect "17 snapshot exists" "$(nsnap)" 2

# 17b: a re-push with only a new generatedAt (same digest/count/bytes) is not a warning
new_world 18
fixture --notes 120; wrap run > /dev/null
echo "failure tail" > "$W/state/last-failure"
cat > "$W/hook.sh" << HOOK
#!/usr/bin/env bash
python3 -I -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); m["generatedAt"]="2099-01-01T00:00:00Z"; json.dump(m, open(p,"w"), sort_keys=True)' "$W/inbox/manifest.json"
HOOK
chmod +x "$W/hook.sh"
export VAULT_BACKUP_POSTCHECK_HOOK="$W/hook.sh"
rc=$(wrap run)
unset VAULT_BACKUP_POSTCHECK_HOOK
expect "17b re-push with new generatedAt only: exit 0 / ok" "$rc $(run_code)" "0 ok"
[[ ! -e "$W/state/last-failure" ]] && pass "17b last-failure removed on success" || fail "17b last-failure removed" "still there"

echo
if [[ "$FAILS" -eq 0 ]]; then echo "ALL PASS"; else echo "$FAILS FAILED"; exit 1; fi
