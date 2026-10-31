#!/usr/bin/env bash
# stage1-check.sh <PUBLIC_URL> [--insecure-loopback [--expect-public-url URL]]
#
# Stage 1 (tailnet-only) black-box check of a running notetaker-remote, from
# the Mac: discovery documents, the unauthenticated surface, request limits.
# Run it from a machine on the tailnet. Needs only curl + jq. No token is used
# or created. Prints one PASS/FAIL/WARN/SKIP line per check; exits 0 only if
# nothing FAILed.
#
#   <PUBLIC_URL>   https://<NODE>.<TAILNET>.ts.net  (no path)
#
# Loopback mode (for testing against a local `notetaker-remote serve`):
#   --insecure-loopback        allow http://127.0.0.1[:port] / http://localhost[:port]
#                              as the URL requests are sent to; the TLS check is skipped,
#                              and /healthz is expected to answer 200 (see below).
#   --expect-public-url URL    the NR_PUBLIC_URL the server was configured with (the server
#                              refuses non-https URLs, so documents name that https URL
#                              while requests go to the loopback address).
#
# Side effect to know about: the last check sends 25 unauthenticated POSTs, which
# trips the server's 401 tarpit for about 60 s. If no client IP is trusted (the
# default, NR_TRUST_FORWARDED_FOR=0) the tarpit key is global, so wait a minute
# before running other scripts. A valid token is never locked out by it, but the
# audit log gets auth.missing / auth.tarpit lines (expected; they are yours).
#
# stage2-check.sh runs this same file with NR_STAGE=2 (public, off-tailnet).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-checks.sh
. "$DIR/lib-checks.sh"

STAGE="${NR_STAGE:-1}"
SELF="$(basename "$0")"
usage() {
  echo "usage: $SELF <PUBLIC_URL> [--insecure-loopback [--expect-public-url URL]]" >&2
  echo "  PUBLIC_URL like https://<NODE>.<TAILNET>.ts.net (the real values, no path)" >&2
  exit 64
}

BASE=""
EXPECT=""
LOOPBACK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --insecure-loopback) LOOPBACK=1 ;;
    --expect-public-url)
      shift
      [[ $# -gt 0 ]] || usage
      EXPECT="$1"
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      [[ -z "$BASE" ]] || usage
      BASE="$1"
      ;;
  esac
  shift
done
[[ -n "$BASE" ]] || usage
is_placeholder "$BASE" && usage
BASE="${BASE%/}"
if [[ $LOOPBACK -eq 1 ]]; then
  [[ "$BASE" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?$ ]] || {
    echo "$SELF: --insecure-loopback only allows http://127.0.0.1[:port] or http://localhost[:port]" >&2
    usage
  }
  EXPECT="${EXPECT:-$BASE}"
  is_placeholder "$EXPECT" && usage
else
  [[ -z "$EXPECT" ]] || usage
  [[ "$BASE" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || {
    echo "$SELF: PUBLIC_URL must be https://<host> with no path (use --insecure-loopback for a local test)" >&2
    usage
  }
  EXPECT="$BASE"
fi
EXPECT="${EXPECT%/}"

need_tools curl jq
make_work

echo "target: $(printable "$BASE")  (documents must name: $(printable "$EXPECT"))  stage: $STAGE"

# --- reachability and TLS ----------------------------------------------------
section "reachability and TLS"
http GET "$BASE/.well-known/oauth-protected-resource"
if [[ "$STATUS" == "000" ]]; then
  fail "cannot reach $(printable "$BASE") ($(printable "$(head -c 200 "$WORK/curl.err")")) - is the Mac on the tailnet (stage 1) / is Funnel on (stage 2), and is the service running? A TLS error here is also a failure: design 4.7 needs the tailscaled-issued certificate to validate without -k."
  finish || true
  exit 1
fi
if [[ $LOOPBACK -eq 1 ]]; then
  skip "TLS chain (loopback http; the public run checks it)"
else
  verify="$(curl -sS --max-time 20 -o /dev/null -w '%{ssl_verify_result}' "$BASE/.well-known/oauth-protected-resource" 2> /dev/null || true)"
  if [[ "$verify" == "0" ]]; then
    pass "TLS chain valid (curl without -k)"
  else
    fail "TLS chain did not verify (ssl_verify_result=$(printable "${verify:-none}")) - design 4.7: tailscaled terminates TLS with a real certificate; enable HTTPS certificates in the tailnet DNS settings"
  fi
fi
if [[ "$STAGE" == "2" && $LOOPBACK -eq 0 ]]; then
  remote_ip="$(curl -sS --max-time 20 -o /dev/null -w '%{remote_ip}' "$BASE/.well-known/oauth-protected-resource" 2> /dev/null || true)"
  # 100.64.0.0/10 (CGNAT, what Tailscale uses) or fd7a:115c:a1e0::/48 means the request rode the tailnet.
  if [[ "$remote_ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. || "$remote_ip" == fd7a:115c:a1e0:* ]]; then
    if [[ "${NR_ALLOW_TAILNET:-0}" == "1" ]]; then
      warn "this request reached the server over the tailnet ($(printable "$remote_ip")), not the public Funnel; NR_ALLOW_TAILNET=1 so the run continues, but it does NOT prove public behaviour"
    else
      fail "this request reached the server over the tailnet ($(printable "$remote_ip")), not the public Funnel - design 7 stage 2 must be verified from a non-tailnet network (phone hotspot, or disconnect Tailscale). Set NR_ALLOW_TAILNET=1 to run anyway."
    fi
  else
    pass "request arrived over the public internet (server address $(printable "${remote_ip:-unknown}"), not a tailnet address)"
  fi
fi

# --- protected resource metadata (RFC 9728) ----------------------------------
section "protected resource metadata (design 4.4)"
for path in /.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/mcp; do
  http GET "$BASE$path"
  if [[ "$STATUS" != "200" ]]; then
    fail "GET $path answered $STATUS - design 4.4: claude.ai fetches the protected-resource document at the path-suffixed and the root location"
    continue
  fi
  if ! body_is_json; then
    fail "GET $path did not return JSON - design 4.4 (RFC 9728)"
    continue
  fi
  if jq -e --arg r "$EXPECT/mcp" '.resource == $r' "$WORK/body" > /dev/null; then
    pass "$path: resource == $(printable "$EXPECT")/mcp"
  else
    fail "$path: resource is '$(printable "$(jq -r '.resource // "(missing)"' "$WORK/body")")', expected '$(printable "$EXPECT")/mcp' - design 4.4: it must equal the URL exactly as typed into the connector; check NR_PUBLIC_URL"
  fi
  if jq -e --arg a "$EXPECT" '(.authorization_servers // []) | index($a) != null' "$WORK/body" > /dev/null; then
    pass "$path: authorization_servers names $(printable "$EXPECT")"
  else
    fail "$path: authorization_servers does not list $(printable "$EXPECT") - design 4.4: the server is its own authorization server"
  fi
done

# --- authorization server metadata (RFC 8414 / OIDC discovery) -----------------
section "authorization server metadata (design 4.4, 9)"
for path in /.well-known/oauth-authorization-server /.well-known/openid-configuration; do
  http GET "$BASE$path"
  if [[ "$STATUS" != "200" ]] || ! body_is_json; then
    fail "GET $path answered $STATUS (or not JSON) - design 4.4: both discovery paths must serve the metadata"
    continue
  fi
  if jq -e --arg i "$EXPECT" '.issuer == $i' "$WORK/body" > /dev/null; then
    pass "$path: issuer == $(printable "$EXPECT")"
  else
    fail "$path: issuer is '$(printable "$(jq -r '.issuer // "(missing)"' "$WORK/body")")' - design 4.4: issuer must be the public URL"
  fi
  if jq -e 'has("registration_endpoint") | not' "$WORK/body" > /dev/null; then
    pass "$path: no registration_endpoint"
  else
    fail "$path: advertises a registration_endpoint - design 9: pre-registered client, NO dynamic client registration"
  fi
  if jq -e '.code_challenge_methods_supported == ["S256"]' "$WORK/body" > /dev/null; then
    pass "$path: PKCE methods are exactly [S256]"
  else
    fail "$path: code_challenge_methods_supported is $(printable "$(jq -c '.code_challenge_methods_supported' "$WORK/body")") - design 4.4: S256 only"
  fi
  if jq -e '(.token_endpoint_auth_methods_supported // []) | index("none") != null' "$WORK/body" > /dev/null; then
    pass "$path: token endpoint auth includes none (public client + PKCE)"
    if ! jq -e '.token_endpoint_auth_methods_supported == ["none"]' "$WORK/body" > /dev/null; then
      warn "$path: token_endpoint_auth_methods_supported is not exactly [none] - the optional client-secret hook (NR_OAUTH_CLIENT_SECRET_SHA256) is on; design 4.4 default is PKCE only"
    fi
  else
    fail "$path: token_endpoint_auth_methods_supported lacks none - design 4.4 / 9: claude.ai connects as a public client with PKCE"
  fi
  if jq -e --arg e "$EXPECT" '(.authorization_endpoint | startswith($e + "/")) and (.token_endpoint | startswith($e + "/"))' "$WORK/body" > /dev/null; then
    pass "$path: authorization and token endpoints live under $(printable "$EXPECT")"
  else
    fail "$path: authorization_endpoint / token_endpoint do not start with $(printable "$EXPECT")/ - design 4.4"
  fi
  if jq -e '.authorization_response_iss_parameter_supported == true' "$WORK/body" > /dev/null; then
    pass "$path: authorization_response_iss_parameter_supported (RFC 9207)"
  else
    warn "$path: authorization_response_iss_parameter_supported is not true - oauth-probe.sh expects the iss parameter"
  fi
done

# --- the unauthenticated surface ---------------------------------------------
section "unauthenticated surface (design 4.2, 4.7, 4.8)"

http POST "$BASE/mcp" -H 'Content-Type: application/json' --data-binary '{}'
challenge="$(hdr www-authenticate)"
if [[ "$STATUS" == "401" ]]; then
  pass "POST /mcp without a token -> 401"
else
  fail "POST /mcp without a token answered $STATUS - design 2: every tool request needs a bearer token"
fi
if [[ "$challenge" == *"resource_metadata="* ]]; then
  pass "401 carries WWW-Authenticate with resource_metadata="
  if [[ "$challenge" == *"$EXPECT/.well-known/oauth-protected-resource/mcp"* ]]; then
    pass "resource_metadata points at $(printable "$EXPECT")/.well-known/oauth-protected-resource/mcp"
  else
    fail "resource_metadata does not point at the PRM document ($(printable "$challenge")) - design 4.4"
  fi
else
  fail "401 has no WWW-Authenticate resource_metadata= (got '$(printable "$challenge")') - design 4.4: claude.ai discovers the authorization server from it"
fi

# MCP 2026-07-28 request shape (specs/mcp-2026/01 section 7.4): the era of the request
# never changes the unauthenticated surface.
http POST "$BASE/mcp" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: server/discover' \
  --data-binary '{"jsonrpc":"2.0","id":"discover-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"ExampleClient","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}'
challenge="$(hdr www-authenticate)"
if [[ "$STATUS" == "401" ]]; then
  pass "POST /mcp server/discover (MCP 2026-07-28) without a token -> 401"
else
  fail "POST /mcp server/discover (MCP 2026-07-28) without a token answered $STATUS - design 10: the era of the request never changes the unauthenticated surface"
fi
if [[ "$challenge" == *"resource_metadata=\"$EXPECT/.well-known/oauth-protected-resource/mcp\""* ]]; then
  pass "the 2026-07-28 401 carries the same resource_metadata= challenge"
else
  fail "the 2026-07-28 401 has no matching WWW-Authenticate resource_metadata= (got '$(printable "$challenge")') - design 10: the era of the request never changes the unauthenticated surface"
fi

for method in GET DELETE; do
  http "$method" "$BASE/mcp" -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: server/discover'
  if [[ "$STATUS" == "405" ]]; then
    pass "$method /mcp -> 405"
  else
    fail "$method /mcp answered $STATUS - design 4.2: the stateless transport exposes only POST /mcp"
  fi
done

for method in GET POST; do
  http "$method" "$BASE/register"
  if [[ "$STATUS" == "404" ]]; then
    pass "$method /register -> 404"
  else
    fail "$method /register answered $STATUS - design 9: there is no dynamic client registration endpoint"
  fi
done

http GET "$BASE/healthz"
if [[ $LOOPBACK -eq 1 ]]; then
  if [[ "$STATUS" == "200" ]]; then
    pass "/healthz -> 200 on the loopback listener (the server's own liveness route; the tailscale serve/funnel mapping must NOT expose it - the non-loopback runs check that)"
  else
    warn "/healthz answered $STATUS on the loopback listener (expected the server's own 200)"
  fi
elif [[ "$STATUS" != "200" ]]; then
  pass "/healthz is not served publicly ($STATUS)"
else
  fail "/healthz answered 200 - design 4.7: only /mcp, /.well-known/*, /authorize, /auth/google/callback, /consent, /token, /revoke are routed; fix the tailscale serve/funnel path mapping (nr-serve-routes status)"
fi
for path in / /admin /index.html; do
  http GET "$BASE$path"
  if [[ "$STATUS" == "404" ]]; then
    pass "GET $path -> 404"
  else
    fail "GET $path answered $STATUS - design 4.7: everything outside the routed prefixes is 404"
  fi
done

# 70 KB body: over the 64 KB ceiling. Sent without a token on purpose: the
# size limit runs before authentication.
head -c 71680 /dev/zero | tr '\0' 'a' > "$WORK/big"
http POST "$BASE/mcp" -H 'Content-Type: application/json' --data-binary @"$WORK/big"
if [[ "$STATUS" == "413" ]]; then
  pass "70 KB body -> 413"
else
  fail "70 KB body answered $STATUS - design 4.8: request bodies are capped at 64 KB"
fi

if [[ "$STAGE" == "2" ]]; then
  http GET "$BASE/auth/google/callback"
  if [[ "$STATUS" == "400" ]]; then
    pass "/auth/google/callback without parameters -> 400"
  elif [[ "${STATUS:0:1}" == "5" ]]; then
    fail "/auth/google/callback without parameters answered $STATUS - design 4.4: a malformed callback is a client error, never a 5xx"
  else
    fail "/auth/google/callback without parameters answered $STATUS, expected 400 - design 4.4"
  fi
fi

# --- flood: LAST, it trips the tarpit ------------------------------------------
section "rate limit (design 4.8) - 25 unauthenticated POSTs, trips the 60 s tarpit"
first429=""
retry=""
n401=0
for i in $(seq 1 25); do
  http POST "$BASE/mcp" -H 'Content-Type: application/json' --data-binary '{}'
  if [[ "$STATUS" == "401" ]]; then
    n401=$((n401 + 1))
  elif [[ "$STATUS" == "429" && -z "$first429" ]]; then
    first429="$i"
    retry="$(hdr retry-after)"
  fi
done
if [[ -n "$first429" ]]; then
  pass "429 after $n401 unauthenticated 401s (first 429 on request $first429)"
  if [[ "$retry" =~ ^[0-9]+$ ]]; then
    pass "429 carries Retry-After: $retry"
  else
    fail "429 without a numeric Retry-After (got '$(printable "$retry")') - design 4.8"
  fi
else
  fail "25 unauthenticated POSTs never produced a 429 ($n401 x 401) - design 4.8: 401s are limited to 20/min, then a 60 s tarpit"
fi
echo "note: wait about 60 s before running stage1-tools.sh or another script against this server."

finish
