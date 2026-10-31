#!/usr/bin/env bash
# stage1-tools.sh <PUBLIC_URL> <client_id> [--insecure-loopback]
#
# Stage 1 (tailnet-only) authenticated check of the MCP tool surface. Logs in
# the way oauth-probe.sh does (PKCE -> /authorize -> Google login in YOUR
# browser -> loopback redirect -> /token), then drives the seven tools over
# POST /mcp and asserts what the design promises. At the end it revokes the
# refresh token (the whole token family dies), so no session is left behind.
#
# Why it logs in itself: oauth-probe.sh keeps its tokens in a private temp
# directory it deletes on exit and prints only their last four characters, so
# there is nothing to hand over. This script reuses the probe's helper
# functions (PROBE_SOURCE_ONLY=1) and does its own login. It needs the server
# to run with NR_ALLOW_LOOPBACK=1 (stage 1 only; stage 2 turns it off, and the
# claude.ai connector itself is the stage-2 tool test).
#
# The login is "paste" style: the script prints an AUTHORIZE_URL, you open it,
# sign in, and your browser lands on http://127.0.0.1:<port>/cb?code=... which
# shows a connection error because nothing listens there. That is fine: copy
# the full URL from the address bar and paste it at the prompt.
#
# Optional environment:
#   LOCKED_PATH       vault path of a note you have locked (its path/title only; never
#                     the contents). read_note on it must NOT return content.
#   LOCKED_SENTINEL   a distinctive string that exists only inside locked note bodies (a
#                     canary). It must appear in no tool response; searched for too.
#   BIG_PATH          vault path of a note larger than 200 KB (optional): truncation check.
#   NR_ACCESS_TOKEN_FILE  skip the login and use the access token in this file (mode 0600).
#   PROBE_PORT (8765), PROBE_TIMEOUT (300 s)
#
# Tokens exist only in a umask-077 mktemp directory removed by a trap; they
# are never printed and never on a command line.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-checks.sh
. "$DIR/lib-checks.sh"
# The probe's pure helpers: b64url, urlencode, urldecode, query_param, valid_code.
# shellcheck source=oauth-probe.sh
PROBE_SOURCE_ONLY=1 . "$DIR/oauth-probe.sh"

SELF="$(basename "$0")"
usage() {
  echo "usage: $SELF <PUBLIC_URL> <client_id> [--insecure-loopback]" >&2
  echo "  PUBLIC_URL  https://<NODE>.<TAILNET>.ts.net   client_id  your NR_OAUTH_CLIENT_ID" >&2
  echo "  optional env: LOCKED_PATH, LOCKED_SENTINEL, BIG_PATH (see the header of this script)" >&2
  exit 64
}

LOOPBACK=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --insecure-loopback) LOOPBACK=1 ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) ARGS+=("$a") ;;
  esac
done
[[ ${#ARGS[@]} -eq 2 ]] || usage
BASE="${ARGS[0]%/}"
CLIENT_ID="${ARGS[1]}"
is_placeholder "$BASE" && usage
is_placeholder "$CLIENT_ID" && usage
if [[ $LOOPBACK -eq 1 ]]; then
  [[ "$BASE" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?$ ]] || usage
else
  [[ "$BASE" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || usage
fi
PORT="${PROBE_PORT:-8765}"
TIMEOUT="${PROBE_TIMEOUT:-300}"
REDIRECT="http://127.0.0.1:${PORT}/cb"

need_tools curl jq openssl
make_work

# --- tool-call plumbing --------------------------------------------------------
: > "$WORK/all-responses"
CALL_ID=10
# mcp <json-body>  -> STATUS; response JSON in $WORK/mcp.json (SSE data: lines unwrapped)
mcp() {
  printf 'Authorization: Bearer %s\n' "$(cat "$WORK/access")" > "$WORK/auth-header"
  STATUS="$(curl -sS --max-time 40 -o "$WORK/mcp.raw" -w '%{http_code}' -X POST "$BASE/mcp" \
    -H @"$WORK/auth-header" -H 'Content-Type: application/json' -H 'Accept: application/json' \
    --data-binary "$1" 2> "$WORK/curl.err")" || STATUS=000
  if jq -e . "$WORK/mcp.raw" > /dev/null 2>&1; then
    cp "$WORK/mcp.raw" "$WORK/mcp.json"
  else
    sed -n 's/^data: //p' "$WORK/mcp.raw" | head -1 > "$WORK/mcp.json"
  fi
  # The sentinel search echoes its own query back; keep that one out of the transcript scan.
  if [[ -z "${NOLOG:-}" ]]; then cat "$WORK/mcp.json" >> "$WORK/all-responses"; fi
}
# mcp_modern <method> <name-or-""> <json-body>  -> STATUS and $WORK/mcp.json (MCP 2026-07-28 headers)
mcp_modern() {
  local method="$1" name="$2" extra=()
  [[ -z "$name" ]] || extra=(-H "Mcp-Name: $name")
  # MV overrides the header version; NO_MCP_METHOD=1 omits the Mcp-Method header.
  [[ -n "${NO_MCP_METHOD:-}" ]] || extra+=(-H "Mcp-Method: $method")
  printf 'Authorization: Bearer %s\n' "$(cat "$WORK/access")" > "$WORK/auth-header"
  STATUS="$(curl -sS --max-time 40 -o "$WORK/mcp.raw" -w '%{http_code}' -X POST "$BASE/mcp" \
    -H @"$WORK/auth-header" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "MCP-Protocol-Version: ${MV:-2026-07-28}" ${extra[@]+"${extra[@]}"} \
    --data-binary "$3" 2> "$WORK/curl.err")" || STATUS=000
  if jq -e . "$WORK/mcp.raw" > /dev/null 2>&1; then
    cp "$WORK/mcp.raw" "$WORK/mcp.json"
  else
    sed -n 's/^data: //p' "$WORK/mcp.raw" | head -1 > "$WORK/mcp.json"
  fi
  if [[ -z "${NOLOG:-}" ]]; then cat "$WORK/mcp.json" >> "$WORK/all-responses"; fi
}
# modern_body <id-json> <method> <params-json> [version]  -> body with the standard _meta
modern_body() {
  jq -nc --argjson id "$1" --arg m "$2" --argjson p "$3" --arg v "${4:-2026-07-28}" \
    '{jsonrpc:"2.0",id:$id,method:$m,params:($p + {_meta:{"io.modelcontextprotocol/protocolVersion":$v,"io.modelcontextprotocol/clientInfo":{name:"stage1-tools",version:"1"},"io.modelcontextprotocol/clientCapabilities":{}}})}'
}
# tool <name> <arguments-json>  -> STATUS and $WORK/mcp.json
tool() {
  CALL_ID=$((CALL_ID + 1))
  mcp "$(jq -nc --argjson id "$CALL_ID" --arg n "$1" --argjson a "$2" \
    '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:$n,arguments:$a}}')"
}
# r <jq filter> -> raw output on the last response ("null" when absent)
r() { jq -r "$1" "$WORK/mcp.json" 2> /dev/null || echo "null"; }
rb() { jq -e "$@" "$WORK/mcp.json" > /dev/null 2>&1; }
SC='.result.structuredContent'
TXT='.result.content[0].text'

# The text content must be framed as untrusted data (design 4.8).
check_framing() {
  local label="$1"
  if rb "($TXT | startswith(\"Vault data below is user content\")) and ($TXT | contains(\"<untrusted_vault_data>\")) and ($TXT | endswith(\"</untrusted_vault_data>\"))"; then
    pass "$label: text content starts with the untrusted-data preamble and is wrapped in <untrusted_vault_data>"
  else
    fail "$label: text content is not framed as untrusted data - design 4.8: a fixed preamble plus <untrusted_vault_data> tags around every payload"
  fi
}

# --- discovery -----------------------------------------------------------------
section "discovery"
http GET "$BASE/.well-known/oauth-protected-resource/mcp"
RESOURCE="$(jq -r '.resource // empty' "$WORK/body" 2> /dev/null || true)"
http GET "$BASE/.well-known/oauth-authorization-server"
ISSUER="$(jq -r '.issuer // empty' "$WORK/body" 2> /dev/null || true)"
if [[ -z "$RESOURCE" || -z "$ISSUER" ]]; then
  fail "metadata documents are missing resource/issuer (HTTP $STATUS) - run stage1-check.sh first (design 4.4)"
  finish || true
  exit 1
fi
echo "resource=$(printable "$RESOURCE") issuer=$(printable "$ISSUER")"

# --- login ---------------------------------------------------------------------
section "login"
if [[ -n "${NR_ACCESS_TOKEN_FILE:-}" ]]; then
  [[ -r "$NR_ACCESS_TOKEN_FILE" ]] || {
    echo "NR_ACCESS_TOKEN_FILE is not a readable file" >&2
    exit 64
  }
  tr -d '\r\n ' < "$NR_ACCESS_TOKEN_FILE" > "$WORK/access"
  : > "$WORK/refresh"
  echo "using the access token from NR_ACCESS_TOKEN_FILE (no login)"
else
  VERIFIER="$(openssl rand 32 | b64url)"
  CHALLENGE="$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | b64url)"
  STATE="$(openssl rand 16 | b64url)"
  AUTH_URL="$BASE/authorize?response_type=code&client_id=$(urlencode "$CLIENT_ID")"
  AUTH_URL+="&redirect_uri=$(urlencode "$REDIRECT")&code_challenge=$CHALLENGE&code_challenge_method=S256"
  AUTH_URL+="&state=$STATE&scope=vault%3Aread&resource=$(urlencode "$RESOURCE")"
  echo "Open this URL, sign in with Google, then paste the full URL your browser ends on"
  echo "(it will show a connection error for 127.0.0.1:$PORT; that is expected)."
  echo "AUTHORIZE_URL $AUTH_URL"
  CALLBACK=""
  read -r -t "$TIMEOUT" -p "redirected URL: " CALLBACK || {
    fail "nothing pasted within ${TIMEOUT}s"
    finish || true
    exit 1
  }
  QUERY="${CALLBACK#*\?}"
  ERR="$(query_param error "$QUERY")"
  if [[ -n "$ERR" ]]; then
    fail "authorization error: $(printable "$(urldecode "$ERR")") - is the server running with NR_ALLOW_LOOPBACK=1 (stage 1)? Design 4.4: loopback redirects exist only in the tailnet stage."
    finish || true
    exit 1
  fi
  CODE="$(query_param code "$QUERY")"
  valid_code "$CODE" || {
    fail "the pasted URL has no well-formed authorization code"
    finish || true
    exit 1
  }
  [[ "$(query_param state "$QUERY")" == "$STATE" ]] || {
    fail "state mismatch (possible CSRF) - design 4.4"
    finish || true
    exit 1
  }
  [[ "$(urldecode "$(query_param iss "$QUERY")")" == "$ISSUER" ]] || {
    fail "iss mismatch (RFC 9207) - design 4.4"
    finish || true
    exit 1
  }
  printf 'grant_type=authorization_code&code=%s&redirect_uri=%s&code_verifier=%s&client_id=%s&resource=%s' \
    "$CODE" "$(urlencode "$REDIRECT")" "$VERIFIER" "$(urlencode "$CLIENT_ID")" "$(urlencode "$RESOURCE")" > "$WORK/form"
  http POST "$BASE/token" -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @"$WORK/form"
  if [[ "$STATUS" != "200" ]]; then
    fail "token exchange returned HTTP $STATUS"
    finish || true
    exit 1
  fi
  jq -r '.access_token // empty' "$WORK/body" > "$WORK/access"
  jq -r '.refresh_token // empty' "$WORK/body" > "$WORK/refresh"
  [[ -s "$WORK/access" ]] || {
    fail "token response lacks an access token"
    finish || true
    exit 1
  }
  pass "login and token exchange succeeded (tokens held in a private temp directory only)"
fi

# --- initialize + tools/list ---------------------------------------------------
section "tools/list (design 4.2)"
mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"stage1-tools","version":"1"}}}'
if [[ "$STATUS" != "200" ]]; then
  fail "initialize answered HTTP $STATUS - the bearer token was not accepted (design 4.4)"
  finish || true
  exit 1
fi
mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}'
mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
jq -c '.result.tools' "$WORK/mcp.json" > "$WORK/tools.legacy.json" 2> /dev/null || : > "$WORK/tools.legacy.json"
WANT='["calendar_agenda","calendar_list","list_folder","read_note","search","tasks","vault_overview"]'
if rb ".result.tools | map(.name) | sort == $WANT"; then
  pass "tools/list has exactly the 7 tools: $(r '.result.tools | map(.name) | sort | join(" ")')"
else
  fail "tools/list names are '$(printable "$(r '.result.tools | map(.name) | sort | join(" ")')")', expected exactly the 7 read-only tools - design 4.2: same seven tools as notetaker-mcp, nothing new"
fi
if rb '.result.tools | all(.annotations.readOnlyHint == true)'; then
  pass "every tool is annotated readOnlyHint:true"
else
  fail "a tool is not annotated readOnlyHint:true - design 4.2"
fi
if rb '(.result.tools[] | select(.name == "search") | .inputSchema.properties | has("mode")) | not'; then
  pass "search schema has no mode property (keyword-only server)"
else
  fail "search schema still advertises mode - design 9: keyword-only search, no embeddings on the container"
fi

# --- MCP 2026-07-28 modern path ----------------------------------------------
section "MCP 2026-07-28 modern path (spec mcp-2026/01)"
mcp_modern server/discover "" "$(modern_body '"d1"' server/discover '{}')"
if [[ "$STATUS" == "200" ]] && rb '.result.resultType == "complete"
  and .result.supportedVersions == ["2026-07-28"]
  and .result.capabilities.tools.listChanged == false
  and (.result.ttlMs | type == "number")
  and (.result.cacheScope | IN("public","private"))
  and .result._meta["io.modelcontextprotocol/serverInfo"].name == "notetaker"'; then
  pass "server/discover: 200, complete, supportedVersions == [2026-07-28], ttlMs/cacheScope, serverInfo"
else
  fail "server/discover answered HTTP $STATUS or the result shape is wrong - spec mcp-2026/01 section 5.1"
fi

mcp_modern tools/list "" "$(modern_body 2 tools/list '{}')"
if [[ "$STATUS" == "200" ]] && rb ".result.tools | map(.name) | sort == $WANT" \
  && rb '.result.tools | all(.annotations.readOnlyHint == true)' \
  && rb '(.result.tools[] | select(.name == "search") | .inputSchema.properties | has("mode")) | not' \
  && rb '(.result.ttlMs | type == "number") and (.result.cacheScope | type == "string")'; then
  pass "modern tools/list: exactly the 7 read-only tools, no search mode, ttlMs/cacheScope present"
else
  fail "modern tools/list (HTTP $STATUS) is not the 7 read-only tools with cache hints - spec mcp-2026/01 section 5.2"
fi
if [[ -s "$WORK/tools.legacy.json" ]] && jq -e --slurpfile legacy "$WORK/tools.legacy.json" '.result.tools == $legacy[0]' "$WORK/mcp.json" > /dev/null 2>&1; then
  pass "modern tools/list equals the legacy tools/list as JSON values"
else
  fail "modern tools/list differs from the legacy tools/list - spec mcp-2026/01 section 5.2: the catalog is identical in both eras"
fi

mcp_modern tools/call vault_overview "$(modern_body 3 tools/call '{"name":"vault_overview","arguments":{}}')"
if [[ "$STATUS" == "200" ]] && rb '.result.resultType == "complete"' && rb "$SC.replica_generated_at | type == \"string\""; then
  pass "modern tools/call vault_overview: 200, complete, replica_generated_at present"
  check_framing "modern vault_overview"
else
  fail "modern tools/call vault_overview answered HTTP $STATUS without a complete result carrying replica_generated_at - spec mcp-2026/01 section 5.3"
fi

mcp_modern tools/call list_folder "$(modern_body 4 tools/call '{"name":"vault_overview","arguments":{}}')"
if [[ "$STATUS" == "400" ]] && rb '.error.code == -32020'; then
  pass "Mcp-Name that does not match params.name -> 400 -32020"
else
  fail "Mcp-Name mismatch answered HTTP $STATUS (code $(printable "$(r '.error.code')")), expected 400 -32020 - spec mcp-2026/01 section 4 step 9"
fi

NO_MCP_METHOD=1 mcp_modern tools/list "" "$(modern_body 5 tools/list '{}')"
if [[ "$STATUS" == "400" ]] && rb '.error.code == -32020'; then
  pass "tools/list without Mcp-Method -> 400 -32020"
else
  fail "tools/list without Mcp-Method answered HTTP $STATUS, expected 400 -32020 - spec mcp-2026/01 section 4 step 6"
fi

MV=2026-12-01 mcp_modern server/discover "" "$(modern_body 6 server/discover '{}' 2026-12-01)"
if [[ "$STATUS" == "400" ]] && rb '.error.code == -32022 and .error.data.supported == ["2026-07-28"] and .error.data.requested == "2026-12-01"'; then
  pass "unsupported version 2026-12-01 -> 400 -32022 with supported [2026-07-28]"
else
  fail "version 2026-12-01 answered HTTP $STATUS (code $(printable "$(r '.error.code')")), expected 400 -32022 - spec mcp-2026/01 section 4 step 5"
fi

mcp_modern ping "" "$(modern_body 7 ping '{}')"
if [[ "$STATUS" == "404" ]] && rb '.error.code == -32601'; then
  pass "modern ping -> 404 -32601"
else
  fail "modern ping answered HTTP $STATUS, expected 404 -32601 - spec mcp-2026/01 section 6.1"
fi

mcp '{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{}}'
if [[ "$STATUS" == "200" ]] && rb ".result.tools | map(.name) | sort == $WANT"; then
  pass "legacy tools/list (no Mcp-Method, no 2026 header) still answers 200 with the 7 tools"
else
  fail "legacy tools/list after the modern requests answered HTTP $STATUS - spec mcp-2026/01: the legacy path must be untouched"
fi

# --- vault_overview ------------------------------------------------------------
section "vault_overview (design 4.1, 4.8)"
tool vault_overview '{}'
if [[ "$STATUS" != "200" ]] || rb '.result.isError == true'; then
  fail "vault_overview failed (HTTP $STATUS): $(printable "$(r "$TXT" | head -c 200)")"
elif rb "$SC.available == false"; then
  fail "vault_overview says available:false - reason: $(printable "$(r "$SC.reason")") (nothing pushed yet, or sharing is switched off in Notetaker)"
else
  if rb "$SC.replica_generated_at | type == \"string\""; then
    pass "replica_generated_at present ($(printable "$(r "$SC.replica_generated_at")"), age $(printable "$(r "$SC.replica_age_minutes")") min)"
  else
    fail "vault_overview lacks replica_generated_at - design 2/4.1: every response carries the replica age"
  fi
  if rb "$SC.stale == false"; then
    pass "stale == false"
  elif rb "$SC.stale == true"; then
    warn "stale == true - the replica is older than the stale threshold; push from the Mac (Settings > Remote > Push now) and re-run"
  else
    fail "vault_overview lacks a boolean stale field - design 2: every response carries stale"
  fi
  if rb "$SC.index_status == \"ok\""; then
    pass "index_status == ok (the container rebuilt its own index)"
  else
    fail "index_status is '$(printable "$(r "$SC.index_status")")', expected ok - design 4.1: the index is rebuilt on the container from the replica; check 'notetaker-remote status'"
  fi
  if rb "$SC.note_count | (type == \"number\") and . > 0"; then
    pass "note_count == $(r "$SC.note_count")"
  else
    fail "note_count is not > 0 - nothing was replicated (push from the Mac)"
  fi
  if rb "$SC | has(\"index_md\") | not"; then
    pass "no _index.md content served (design 1: _index.md never leaves the Mac)"
  else
    fail "vault_overview returned index_md - design 1/5: an _index.md reached the replica (gate 1 failed); run audit-replica on the container"
  fi
  check_framing "vault_overview"
fi

# --- list_folder ---------------------------------------------------------------
section "list_folder (design 1, 5)"
tool list_folder '{"path":""}'
if rb '.result.isError != true'; then
  n_locked="$(r "[$SC.notes[]? | select(.locked == true)] | length")"
  if [[ "$n_locked" == "0" ]]; then
    pass "root listing: no locked note present in the replica ($(r "$SC.notes | length") notes)"
  else
    fail "root listing shows $n_locked locked note(s) - design 5: locked notes must never be in the replica (gate 1 = ExportPolicy on the Mac); gate 2 (server redaction) is only the backstop"
  fi
  if rb "$SC | has(\"index_md\") | not"; then
    pass "root listing is computed, not an exported _index.md"
  else
    fail "root listing came from an _index.md file in the replica - design 1: _index.md is dropped by the export filter"
  fi
  if rb "[$SC.notes[]?.path | select(endswith(\"_index.md\"))] | length == 0"; then
    pass "no _index.md among the listed notes"
  else
    fail "an _index.md is listed - design 1/5"
  fi
  check_framing "list_folder"
else
  fail "list_folder '' failed: $(printable "$(r "$TXT" | head -c 200)")"
fi

# --- search --------------------------------------------------------------------
section "search (design 5, 9)"
tool search '{"query":"locked"}'
if rb '.result.isError != true'; then
  bad="$(r "[$SC.results[]? | select(.locked == true)] | length")"
  leak="$(r "[$SC.results[]? | select(.locked == true and has(\"snippet\"))] | length")"
  if [[ "$leak" != "0" ]]; then
    fail "search returned a locked note WITH a snippet ($leak) - design 5: bodies of locked notes must never be served (both gates failed)"
  elif [[ "$bad" != "0" ]]; then
    fail "search returned $bad locked note(s) (title only) - design 5: locked notes must not be in the replica at all; gate 1 (ExportPolicy) failed, gate 2 redacted the body"
  else
    pass "search 'locked': $(r "$SC.results | length") result(s), every one locked == false"
  fi
  if rb "$SC.semantic == false"; then
    pass "search reports semantic:false (keyword-only)"
  else
    warn "search did not report semantic:false (got '$(printable "$(r "$SC.semantic")")')"
  fi
  check_framing "search"
else
  fail "search failed: $(printable "$(r "$TXT" | head -c 200)")"
fi
if [[ -n "${LOCKED_SENTINEL:-}" ]]; then
  NOLOG=1 tool search "$(jq -nc --arg q "$LOCKED_SENTINEL" '{query:$q}')"
  # Search ORs the words of the query, so common words can match ordinary notes;
  # what matters is that no result carries the sentinel itself.
  if rb '.result.isError != true' && rb --arg s "$LOCKED_SENTINEL" "[$SC.results[]? | tostring | contains(\$s)] | any | not"; then
    pass "search for LOCKED_SENTINEL: no result contains it ($(r "$SC.results | length") unrelated word match(es) at most)"
  else
    fail "search for LOCKED_SENTINEL returned a result containing it (or failed) - design 5: locked content must not be searchable remotely"
  fi
else
  skip "LOCKED_SENTINEL not set (a canary string that exists only in a locked note; see the script header)"
fi

# --- read_note: locked ---------------------------------------------------------
section "read_note (design 5)"
if [[ -n "${LOCKED_PATH:-}" ]]; then
  tool read_note "$(jq -nc --arg p "$LOCKED_PATH" '{path:$p}')"
  if rb '.result.isError == true'; then
    pass "read_note on the locked path: error ($(printable "$(r "$TXT" | head -c 80)")) - the file is not in the replica at all, as designed"
  elif rb "$SC.locked == true" && rb "$SC | has(\"content\") | not"; then
    fail "read_note on the locked path returned a locked note (title only, no content) - design 5: the file must not exist in the replica; gate 1 (ExportPolicy) failed and only gate 2 held. Run 'notetaker-remote audit-replica' on the container and report it."
  elif rb "$SC | has(\"content\")"; then
    fail "read_note on the locked path returned CONTENT - design 5: both gates failed. Run the container kill switch (drill-kill-ct.md) now."
  else
    fail "read_note on the locked path returned something unexpected: $(printable "$(r "$TXT" | head -c 120)")"
  fi
else
  skip "LOCKED_PATH not set (the vault path of a note you locked; path only)"
fi

# --- read_note: truncation -----------------------------------------------------
if [[ -n "${BIG_PATH:-}" ]]; then
  tool read_note "$(jq -nc --arg p "$BIG_PATH" '{path:$p}')"
  if rb '.result.isError == true'; then
    fail "read_note BIG_PATH failed: $(printable "$(r "$TXT" | head -c 120)")"
  else
    cap=204800
    got="$(r "$SC.content | utf8bytelength")"
    if rb "$SC.truncated == true"; then
      total="$(r "$SC.content_bytes")"
      if [[ "$total" =~ ^[0-9]+$ && "$total" -gt $cap && "$got" -le $cap ]]; then
        pass "BIG_PATH truncated consistently: served $got bytes of $total (cap $cap)"
      else
        fail "BIG_PATH truncated:true but content_bytes=$(printable "$total") / served=$(printable "$got") disagree with the 200 KB cap - design 4.8"
      fi
    elif [[ "$got" =~ ^[0-9]+$ && "$got" -le $cap ]]; then
      warn "BIG_PATH was served whole ($got bytes <= $cap): it is not larger than 200 KB, so truncation was not exercised"
    else
      fail "BIG_PATH served $(printable "$got") bytes without truncated:true - design 4.8: read_note is capped at 200 KB"
    fi
  fi
else
  skip "BIG_PATH not set (optional: a note larger than 200 KB)"
fi

# --- calendar ------------------------------------------------------------------
section "calendar_agenda (design 4.8, 9)"
tool calendar_agenda "$(jq -nc --arg f "$(day_plus 0)" --arg t "$(day_plus 61)" '{range:"custom",from:$f,to:$t}')"
if rb '.result.isError == true' && rb "$TXT | contains(\"max 60 days\")"; then
  pass "a 62-day custom range is refused: $(printable "$(r "$TXT" | head -c 80)")"
else
  fail "a 62-day custom range was not refused with 'max 60 days' (got: $(printable "$(r "$TXT" | head -c 100)")) - design 4.8: calendar custom range <= 60 days"
fi
tool calendar_agenda "$(jq -nc --arg f "$(day_plus 0)" --arg t "$(day_plus 6)" '{range:"custom",from:$f,to:$t}')"
if rb '.result.isError != true'; then
  if rb "$SC.available == false"; then
    warn "a 7-day range is accepted but the replica has no calendar (available:false: $(printable "$(r "$SC.reason")")) - expected only if you did not enable the calendar in Settings > Remote"
  else
    pass "a 7-day range is accepted ($(r "$SC.events | length // 0") event(s))"
    check_framing "calendar_agenda"
  fi
else
  fail "a 7-day range failed: $(printable "$(r "$TXT" | head -c 120)")"
fi

# --- nothing locked anywhere in the transcript ---------------------------------
section "transcript scan"
if [[ -n "${LOCKED_SENTINEL:-}" ]]; then
  if grep -qF -e "$LOCKED_SENTINEL" "$WORK/all-responses"; then
    fail "LOCKED_SENTINEL appeared in a tool response - design 5: locked content leaked"
  else
    pass "LOCKED_SENTINEL appears in none of this run's responses"
  fi
else
  skip "LOCKED_SENTINEL not set"
fi

# --- cleanup: kill the session -------------------------------------------------
section "cleanup"
if [[ -s "$WORK/refresh" ]]; then
  printf 'token=%s&client_id=%s' "$(cat "$WORK/refresh")" "$(urlencode "$CLIENT_ID")" > "$WORK/revoke-form"
  http POST "$BASE/revoke" -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @"$WORK/revoke-form"
  if [[ "$STATUS" == "200" ]]; then
    mcp '{"jsonrpc":"2.0","id":99,"method":"tools/list","params":{}}'
    if [[ "$STATUS" == "401" ]]; then
      pass "refresh token revoked; the access token is now rejected (401) - /revoke works"
    else
      warn "refresh token revoked (200) but the access token still answers HTTP $STATUS"
    fi
  else
    warn "POST /revoke answered $STATUS; the session expires on its own (access 15 min)"
  fi
else
  skip "no refresh token held (NR_ACCESS_TOKEN_FILE run); the access token expires on its own"
fi

finish
