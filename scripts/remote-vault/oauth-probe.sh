#!/usr/bin/env bash
# oauth-probe.sh <PUBLIC_URL> <client_id>
#
# Stage-1 OAuth check for notetaker-remote (specs/remote-vault/07). Runs the
# whole client side of the flow against the server, the way Claude would:
#   PKCE + state → /authorize (you log in with Google in a browser) → loopback
#   callback → /token → /mcp initialize, tools/list, tools/call vault_overview
#   → refresh once → re-use the OLD refresh token (must be invalid_grant) →
#   the rotated access token must now be 401 (family revoked).
#
# Needs the server running with NR_ALLOW_LOOPBACK=1 (loopback redirect).
# Tokens live only in a mktemp directory removed on exit; only their last 4
# characters are ever printed. Tokens never appear on a command line (curl
# reads the Authorization header and form bodies from files).
#
# Environment: PROBE_PORT (default 8765), PROBE_TIMEOUT seconds (default 300).
# Exit 0 only if every step behaved as expected.
set -euo pipefail

# --- pure helpers (sourceable for tests: PROBE_SOURCE_ONLY=1 . oauth-probe.sh) ---
step() { echo "== $*"; }
# Everything printed that came from the network goes through this. It keeps
# printable ASCII only: C0 controls (ESC, BEL, CR, ...), DEL, and every byte
# >= 0x80 go — which removes C1 controls (U+0080-U+009F, e.g. the 8-bit CSI
# 0x9B) whether they arrive UTF-8 encoded or raw. Every value this probe prints
# (URLs, error codes, issuer, token tails) is ASCII by protocol.
printable() { printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177-\377'; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
last4() { printf '...%s' "$(printable "${1: -4}")"; }
# Flat JSON only (every document this probe reads is compact and flat enough).
json_field() { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | head -1; }
urlencode() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}
# Percent-decoding only: backslashes are escaped first, so printf %b expands
# nothing but the \xHH this function itself produced. The result is still
# untrusted — print it only through `printable`.
urldecode() {
  local s="${1//+/ }"
  s="${s//\\/\\\\}"
  printf '%b' "$(printf '%s' "$s" | sed -E 's/%([0-9A-Fa-f]{2})/\\x\1/g')"
}
query_param() { printf '%s' "$2" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
# Our authorization codes are base64url; anything else is refused before it is
# echoed or spliced into a form body.
valid_code() { [[ ${#1} -le 512 && "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

if [[ -n "${PROBE_SOURCE_ONLY:-}" ]]; then
  return 0
fi

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <PUBLIC_URL> <client_id>" >&2
  exit 64
fi
BASE="${1%/}"
CLIENT_ID="$2"
PORT="${PROBE_PORT:-8765}"
TIMEOUT="${PROBE_TIMEOUT:-300}"
REDIRECT="http://127.0.0.1:${PORT}/cb"

for tool in curl openssl; do
  if ! command -v "$tool" > /dev/null; then
    echo "FAIL: $tool is required" >&2
    exit 69
  fi
done

umask 077
WORK="$(mktemp -d)"
NC_PID=""
cleanup() {
  if [[ -n "$NC_PID" ]]; then kill "$NC_PID" 2> /dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
# curl with the bearer token read from a file, never from argv.
mcp_call() { # <token-file> <json-body> <out-file> → prints HTTP status
  printf 'Authorization: Bearer %s\n' "$(cat "$1")" > "$WORK/auth-header"
  curl -sS -o "$3" -w '%{http_code}' -X POST "$BASE/mcp" \
    -H @"$WORK/auth-header" -H 'Content-Type: application/json' -H 'Accept: application/json' \
    --data-binary "$2"
}
token_call() { # <form-file> <out-file> → prints HTTP status
  curl -sS -o "$2" -w '%{http_code}' -X POST "$BASE/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @"$1"
}

step "discovery"
RESOURCE="$(curl -fsS "$BASE/.well-known/oauth-protected-resource/mcp" | json_field resource)"
ISSUER="$(curl -fsS "$BASE/.well-known/oauth-authorization-server" | json_field issuer)"
[[ -n "$RESOURCE" && -n "$ISSUER" ]] || fail "metadata documents are missing resource/issuer"
echo "resource=$(printable "$RESOURCE") issuer=$(printable "$ISSUER")"

VERIFIER="$(openssl rand 32 | b64url)"
CHALLENGE="$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | b64url)"
STATE="$(openssl rand 16 | b64url)"

AUTH_URL="$BASE/authorize?response_type=code&client_id=$(urlencode "$CLIENT_ID")"
AUTH_URL+="&redirect_uri=$(urlencode "$REDIRECT")&code_challenge=$CHALLENGE&code_challenge_method=S256"
AUTH_URL+="&state=$STATE&scope=vault%3Aread&resource=$(urlencode "$RESOURCE")"

# --- loopback callback listener -------------------------------------------
# One `nc -l` per connection. The HTTP response is held back on a FIFO until
# the browser's GET has actually arrived: piping a canned response into nc's
# stdin makes nc send it the instant it accepts, before the client has written
# its request, and a client that sees an unsolicited response can drop the
# connection without ever sending the GET (that race lost the callback).
RESPONSE=$'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 46\r\nConnection: close\r\n\r\nnotetaker oauth-probe: you can close this tab\n'
LISTEN_ATTEMPT=0

# Is something LISTENing on 127.0.0.1:$PORT? (No connect: that would consume nc.)
# 0 = yes, 1 = no, 2 = cannot tell on this system.
port_listening() {
  if command -v lsof > /dev/null; then
    lsof -nP -iTCP@127.0.0.1:"$PORT" -sTCP:LISTEN -t > /dev/null 2>&1
  elif command -v ss > /dev/null; then
    ss -Hltn "sport = :$PORT" 2> /dev/null | grep -q .
  else
    return 2
  fi
}

# Starts one listener. Returns 0 when it is accepting, 1 if nc died first.
start_listener() {
  LISTEN_ATTEMPT=$((LISTEN_ATTEMPT + 1))
  local dir="$WORK/listen$LISTEN_ATTEMPT" state
  # macOS nc binds with SO_REUSEPORT, so a second listener on a busy port
  # "succeeds" and the callback could land in the other process: refuse instead.
  if port_listening; then
    echo "listener: 127.0.0.1:$PORT is already in use by another process (set PROBE_PORT)" >&2
    return 1
  fi
  mkdir "$dir"
  mkfifo "$dir/response"
  : > "$dir/request"
  (
    nc -l 127.0.0.1 "$PORT" < "$dir/response" > "$dir/request" 2> "$dir/nc.err"
    echo "$?" > "$dir/nc.status"
  ) &
  NC_PID=$!
  disown "$NC_PID" 2> /dev/null || true # no "Terminated" job notice on cleanup
  LISTEN_DIR="$dir"
  exec 4> "$dir/response" # unblocks the reader; nc's stdin stays open and empty
  for _ in $(seq 1 100); do
    if [[ -e "$dir/nc.status" ]]; then
      echo "listener: nc exited (status $(cat "$dir/nc.status")) before accepting: $(printable "$(head -c 300 "$dir/nc.err")")" >&2
      exec 4>&-
      return 1
    fi
    state=0
    port_listening || state=$?
    if [[ $state -eq 0 ]]; then
      return 0
    elif [[ $state -eq 2 ]]; then
      sleep 0.3 # no lsof/ss: cannot observe the bind; give nc a moment
      [[ -e "$dir/nc.status" ]] && continue
      return 0
    fi
    sleep 0.05
  done
  echo "listener: 127.0.0.1:$PORT never reached LISTEN within 5s" >&2
  exec 4>&-
  return 1
}

stop_listener() {
  { exec 4>&-; } 2> /dev/null || true # group: a bare `exec ... 2>` would silence stderr for good
  if [[ -n "$NC_PID" ]]; then kill "$NC_PID" 2> /dev/null || true; fi
  NC_PID=""
}

paste_callback() {
  step "$1: open this URL, sign in, then paste the full URL the browser ends on:"
  echo "AUTHORIZE_URL $AUTH_URL"
  read -r -t "$TIMEOUT" -p "redirected URL: " CALLBACK_QUERY || fail "nothing pasted within ${TIMEOUT}s"
}

CALLBACK_QUERY=""
if command -v nc > /dev/null && command -v mkfifo > /dev/null; then
  if start_listener; then
    echo "LISTENING 127.0.0.1:$PORT"
    step "open this URL in a browser on this machine and sign in with Google:"
    echo "AUTHORIZE_URL $AUTH_URL"
    deadline=$((SECONDS + TIMEOUT))
    while [[ -z "$CALLBACK_QUERY" ]]; do
      if grep -q '^GET ' "$LISTEN_DIR/request" 2> /dev/null; then
        printf '%s' "$RESPONSE" >&4 # answer only now that the request is in
        exec 4>&-
        REQUEST_LINE="$(head -1 "$LISTEN_DIR/request" | tr -d '\r')"
        CALLBACK_QUERY="${REQUEST_LINE#GET }"
        CALLBACK_QUERY="${CALLBACK_QUERY%% HTTP/*}"
        for _ in $(seq 1 20); do # let nc flush the response, then stop it
          [[ -e "$LISTEN_DIR/nc.status" ]] && break
          sleep 0.05
        done
        stop_listener
        break
      fi
      if [[ -e "$LISTEN_DIR/nc.status" ]]; then
        # A connection came and went without a GET (stray probe, browser preconnect).
        echo "listener: connection closed without a request ($(wc -c < "$LISTEN_DIR/request" | tr -d ' ') bytes, nc status $(cat "$LISTEN_DIR/nc.status")); listening again" >&2
        stop_listener
        start_listener || {
          paste_callback "listener failed"
          break
        }
      fi
      ((SECONDS < deadline)) || fail "no callback on 127.0.0.1:$PORT within ${TIMEOUT}s (listener attempts: $LISTEN_ATTEMPT)"
      sleep 0.1
    done
  else
    stop_listener
    paste_callback "could not listen on 127.0.0.1:$PORT"
  fi
else
  paste_callback "nc or mkfifo not found"
fi
CALLBACK_QUERY="${CALLBACK_QUERY#*\?}"

ERROR="$(query_param error "$CALLBACK_QUERY")"
[[ -z "$ERROR" ]] || fail "authorization error: $(printable "$(urldecode "$ERROR")")"
CODE="$(query_param code "$CALLBACK_QUERY")"
[[ -n "$CODE" ]] || fail "no code in the callback"
valid_code "$CODE" || fail "the callback's code is not a well-formed authorization code"
[[ "$(query_param state "$CALLBACK_QUERY")" == "$STATE" ]] || fail "state mismatch (possible CSRF)"
[[ "$(urldecode "$(query_param iss "$CALLBACK_QUERY")")" == "$ISSUER" ]] || fail "iss mismatch (RFC 9207 mix-up check)"
echo "code received $(last4 "$CODE")"

step "token exchange"
printf 'grant_type=authorization_code&code=%s&redirect_uri=%s&code_verifier=%s&client_id=%s&resource=%s' \
  "$CODE" "$(urlencode "$REDIRECT")" "$VERIFIER" "$(urlencode "$CLIENT_ID")" "$(urlencode "$RESOURCE")" > "$WORK/form"
STATUS="$(token_call "$WORK/form" "$WORK/tokens.json")"
[[ "$STATUS" == "200" ]] || fail "token exchange returned HTTP $STATUS"
json_field access_token < "$WORK/tokens.json" > "$WORK/access1"
json_field refresh_token < "$WORK/tokens.json" > "$WORK/refresh1"
[[ -s "$WORK/access1" && -s "$WORK/refresh1" ]] || fail "token response lacks tokens"
echo "access $(last4 "$(cat "$WORK/access1")"), refresh $(last4 "$(cat "$WORK/refresh1")")"

step "mcp"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"oauth-probe","version":"1"}}}'
[[ "$(mcp_call "$WORK/access1" "$INIT" "$WORK/mcp")" == "200" ]] || fail "initialize"
mcp_call "$WORK/access1" '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$WORK/mcp" > /dev/null
[[ "$(mcp_call "$WORK/access1" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' "$WORK/mcp")" == "200" ]] ||
  fail "tools/list"
grep -q '"vault_overview"' "$WORK/mcp" || fail "tools/list lacks vault_overview"
echo "tools: $(grep -o '"name":"[a-z_]*"' "$WORK/mcp" | sed 's/"name":"//; s/"//' | sort -u | tr '\n' ' ')"
CALL='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"vault_overview","arguments":{}}}'
[[ "$(mcp_call "$WORK/access1" "$CALL" "$WORK/mcp")" == "200" ]] || fail "tools/call vault_overview"
grep -q '"result"' "$WORK/mcp" || fail "vault_overview returned no result"
echo "vault_overview ok"

step "refresh (rotation)"
printf 'grant_type=refresh_token&refresh_token=%s&client_id=%s' "$(cat "$WORK/refresh1")" "$(urlencode "$CLIENT_ID")" \
  > "$WORK/refresh-form"
STATUS="$(token_call "$WORK/refresh-form" "$WORK/tokens2.json")"
[[ "$STATUS" == "200" ]] || fail "refresh returned HTTP $STATUS"
json_field access_token < "$WORK/tokens2.json" > "$WORK/access2"
json_field refresh_token < "$WORK/tokens2.json" > "$WORK/refresh2"
[[ "$(cat "$WORK/refresh2")" != "$(cat "$WORK/refresh1")" ]] || fail "refresh token was not rotated"
echo "rotated: access $(last4 "$(cat "$WORK/access2")"), refresh $(last4 "$(cat "$WORK/refresh2")")"

step "re-use of the old refresh token (must be rejected and revoke the family)"
STATUS="$(token_call "$WORK/refresh-form" "$WORK/reuse.json")"
REUSE_ERROR="$(json_field error < "$WORK/reuse.json")"
[[ "$STATUS" == "400" && "$REUSE_ERROR" == "invalid_grant" ]] || fail "reuse returned HTTP $(printable "$STATUS") $(printable "${REUSE_ERROR:-}")"
AFTER="$(mcp_call "$WORK/access2" '{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}' "$WORK/mcp")"
[[ "$AFTER" == "401" ]] || fail "rotated access token still works after reuse (HTTP $AFTER)"
echo "reuse detected: invalid_grant; family revoked: 401"
