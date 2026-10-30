# shellcheck shell=bash
# lib-checks.sh — shared helpers for the remote-vault stage scripts
# (stage1-check.sh, stage1-tools.sh, stage2-check.sh). Sourced, never run.
#
# Conventions:
#   * every check prints exactly one PASS / FAIL / WARN / SKIP line;
#   * a FAIL line names the design section it contradicts
#     (specs/remote-vault/00-security-design.md);
#   * the script exits 0 only if no check FAILed (WARN and SKIP do not fail);
#   * nothing secret is stored or printed: bearer tokens live in files inside a
#     umask-077 mktemp directory that a trap removes, and reach curl through
#     `-H @file` / `--data-binary @file`, never through argv.

PASS_N=0
FAIL_N=0
WARN_N=0
SKIP_N=0

pass() {
  PASS_N=$((PASS_N + 1))
  echo "PASS: $*"
}
fail() {
  FAIL_N=$((FAIL_N + 1))
  echo "FAIL: $*"
}
warn() {
  WARN_N=$((WARN_N + 1))
  echo "WARN: $*"
}
skip() {
  SKIP_N=$((SKIP_N + 1))
  echo "SKIP: $*"
}
section() { echo "== $*"; }

# Prints the summary and returns non-zero when any check failed.
finish() {
  echo "== summary: ${PASS_N} passed, ${FAIL_N} failed, ${WARN_N} warnings, ${SKIP_N} skipped"
  if [[ $FAIL_N -eq 0 ]]; then
    echo "RESULT: OK"
    return 0
  fi
  echo "RESULT: FAILED (${FAIL_N} check(s) contradict the design; each FAIL line names the section)"
  return 1
}

# Printable ASCII only. Everything that came from the network and is echoed
# goes through this (terminal-escape defence, same rule as oauth-probe.sh).
printable() { printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177-\377'; }

need_tools() {
  local t
  for t in "$@"; do
    if ! command -v "$t" > /dev/null 2>&1; then
      echo "FAIL: $t is required but not installed" >&2
      exit 69
    fi
  done
}

# A placeholder copied straight from the runbook (<NODE>, <PUBLIC_URL>, ...)
# or an empty value is a usage error, never a request.
is_placeholder() {
  [[ -z "$1" || "$1" == *"<"* || "$1" == *">"* || "$1" == *"NODE"* || "$1" == *"TAILNET"* || "$1" == *"CLIENT_ID"* ]]
}

# umask 077 + a private work directory removed on exit.
make_work() {
  umask 077
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
}

# http METHOD URL [curl args...]
#   → STATUS (000 when curl itself failed), $WORK/hdr, $WORK/body.
# Never uses -k: a certificate problem is a failure, not something to skip.
http() {
  local method="$1" url="$2"
  shift 2
  rm -f "$WORK/hdr" "$WORK/body"
  : > "$WORK/hdr"
  : > "$WORK/body"
  STATUS="$(curl -sS --max-time 20 -X "$method" -D "$WORK/hdr" -o "$WORK/body" -w '%{http_code}' "$@" "$url" 2> "$WORK/curl.err")" || STATUS=000
}

# hdr NAME → value of the first such response header (case-insensitive), CR stripped.
hdr() {
  awk -v want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
    { k = $0; sub(/:.*/, "", k); if (tolower(k) == want) { sub(/^[^:]*:[ \t]*/, ""); sub(/\r$/, ""); print; exit } }
  ' "$WORK/hdr"
}

# True when $WORK/body parses as JSON.
body_is_json() { jq -e . "$WORK/body" > /dev/null 2>&1; }

# Portable "today + N days" (macOS date -v, GNU date -d), UTC, yyyy-mm-dd.
day_plus() {
  local n="$1"
  date -u -v"+${n}d" +%Y-%m-%d 2> /dev/null || date -u -d "+${n} days" +%Y-%m-%d
}
