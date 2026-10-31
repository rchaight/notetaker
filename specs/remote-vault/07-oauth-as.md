# Spec 07 — OAuth 2.1 authorization server with Google login (pre-registered client)

Design: `00-security-design.md` §4.4 (what Claude requires; flow; tokens),
§2 (stolen access/refresh token rows; compromised Google account = master
key, accepted), §4.8 (auth rate limits, audit events), §9 (pre-registered
client, NO dynamic registration), §7 T7. Depends on spec 06. Builder:
**opus**. Stage: 1 with `NR_ALLOW_LOOPBACK=1` (probe script, MCP
Inspector), 2 with `NR_ALLOW_LOOPBACK=0` (claude.ai web, then phone).
Final critique (fable) before merge.

## Scope

Inside `Packages/RemoteServer`: the server becomes its own authorization
server for exactly one client (claude.ai, fixed `client_id`) and one
human (`NR_ALLOWED_EMAIL`, verified by Google OIDC). Endpoints: AS
metadata (RFC 8414 + OIDC discovery alias), `/authorize`,
`/auth/google/callback`, `/consent`, `/token`, `/revoke`. Opaque tokens
hashed at rest, 15-minute access tokens, rotating refresh tokens with
family revocation on reuse, `resource` binding, per-IP auth rate limits,
audit events, a `TokenAuthenticator` that replaces 06's `DenyAll`, and the
`scripts/remote-vault/oauth-probe.sh` stage-1 client. Tests run against a
fake Google with real RSA-signed ID tokens.

Builders never create Google credentials or touch the user's accounts; the
runbook (08) has the user create the Google OAuth client and paste its ID
and secret into `/etc/notetaker-remote/env`.

## Design

### Config (parsed by 06's `RemoteConfig`, validated here)

| var | required when serving | notes |
|---|---|---|
| `NR_ALLOWED_EMAIL` | yes | compared case-folded, exact |
| `NR_OAUTH_CLIENT_ID` | yes | opaque, ≥ 16 chars; the runbook generates `nr-` + 32 base64url chars; the user pastes it into the claude.ai connector dialog |
| `NR_OAUTH_REDIRECT_URIS` | no | comma-separated; default `https://claude.ai/api/mcp/auth_callback`; exact string match (RFC 8252 §7.3 port-agnostic loopback only via the next flag) |
| `NR_ALLOW_LOOPBACK` | no | `0`; when `1`, `http://127.0.0.1:<any>/<any>` and `http://localhost:<any>/<any>` are also accepted (stage 1 only; `status` warns; 08 sets it to `0` before Funnel) |
| `NR_GOOGLE_CLIENT_ID`, `NR_GOOGLE_CLIENT_SECRET` | yes | confidential Google "Web application" client; redirect `PUBLIC_URL/auth/google/callback` |
| `NR_GOOGLE_ISSUER` | no | `https://accounts.google.com` — tests point it at the fake |
| `NR_ACCESS_TTL_SEC` / `NR_REFRESH_IDLE_DAYS` / `NR_REFRESH_ABSOLUTE_DAYS` / `NR_CODE_TTL_SEC` | no | 900 / 14 / 30 / 60 — tests shorten them; production leaves defaults |

Optional hook (overview open question 3): `NR_OAUTH_CLIENT_SECRET_SHA256`
— when set, `/token` additionally requires `client_secret_post` or
`client_secret_basic` matching it and metadata advertises those methods
instead of `none`. Implement the switch (it is ~20 lines and one test),
default unset.

### Metadata — `GET /.well-known/oauth-authorization-server` and `GET /.well-known/openid-configuration` (same document)

```json
{ "issuer": "<PUBLIC_URL>",
  "authorization_endpoint": "<PUBLIC_URL>/authorize",
  "token_endpoint": "<PUBLIC_URL>/token",
  "revocation_endpoint": "<PUBLIC_URL>/revoke",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["none"],
  "revocation_endpoint_auth_methods_supported": ["none"],
  "scopes_supported": ["vault:read"],
  "authorization_response_iss_parameter_supported": true }
```
No `registration_endpoint`, no `client_id_metadata_document_supported`,
no `jwks_uri` (tokens are opaque). `Cache-Control: max-age=3600`.

### `GET /authorize`

Validate in this order; **the first two failures render a 400 HTML page
and never redirect** (an unvalidated `redirect_uri` is never a redirect
target):

1. `client_id == NR_OAUTH_CLIENT_ID` (constant-time compare).
2. `redirect_uri` exactly ∈ allowlist (plus loopback rule when enabled).
3. `response_type == "code"`; `code_challenge` 43–128 chars of
   `[A-Za-z0-9._~-]`; `code_challenge_method == "S256"` (required — no
   `plain`, no absence); `state` present, ≤ 512 chars; `scope` absent or ⊆
   {`vault:read`}; `resource`, if present, == `resourceURL`
   (`PUBLIC_URL/mcp`) else error `invalid_target`; absent → accepted and
   audited `authorize.no_resource` (there is exactly one resource; the
   token is bound to it regardless — strict where it matters, tolerant
   where Claude's behaviour is unverified). Failures here → 302 to the
   validated `redirect_uri` with `error`, `error_description`, `state`.
4. Store `PendingAuthorization { gstate (32 random bytes b64url), nonce
   (32 bytes), googleVerifier (PKCE for Google), clientState,
   redirectURI, codeChallenge, resource, createdAt }` in an in-memory
   actor: TTL 10 min, cap 100 (evict oldest), single use.
5. 302 to `<issuer>/o/oauth2/v2/auth` (discovered from
   `NR_GOOGLE_ISSUER/.well-known/openid-configuration`, cached 24 h)
   with `client_id, redirect_uri=PUBLIC_URL/auth/google/callback,
   response_type=code, scope=openid email, state=gstate, nonce,
   code_challenge (S256 of googleVerifier), code_challenge_method=S256,
   prompt=select_account, access_type=online`.

### `GET /auth/google/callback?code&state`

1. Lookup + remove pending by `state`; unknown/expired → 400 page.
2. `POST <token_endpoint>` (10 s timeout; `URLSession` via
   `FoundationNetworking` on Linux) with `code, client_id, client_secret,
   redirect_uri, grant_type=authorization_code, code_verifier`.
3. Parse `id_token` (compact JWS). Verify: header `alg == RS256`, `kid` in
   JWKS (`jwks_uri` from discovery; cached per `Cache-Control` max-age, min
   5 min, max 24 h; one forced refetch on unknown `kid`); signature with
   swift-crypto `_CryptoExtras`: `_RSA.Signing.PublicKey(n:e:)` built from
   the JWK, `isValidSignature(_:for:padding: .insecurePKCS1v1_5)` over
   `header.payload`; claims: `iss` ∈ {issuer, issuer without scheme},
   `aud == NR_GOOGLE_CLIENT_ID`, `exp > now`, `iat ≤ now + 300`,
   `nonce == pending.nonce`, `email_verified == true`,
   `email.lowercased() == NR_ALLOWED_EMAIL.lowercased()`.
4. Any failure → 403 HTML "This vault is not shared with that account."
   + audit `login.denied { reason, email_domain, email_hash8 }` (never the
   full foreign email — it is someone else's PII). Success → audit
   `login.ok`.
5. Render the consent page: "Allow **<redirect host>** (Claude) to read
   your Notetaker vault? Scope: vault:read." with Allow/Deny forms posting
   to `/consent` with a hidden single-use `consent_token` (32 bytes, 5-min
   TTL, bound to the pending record's data, stored in the same actor).
   No cookies, no sessions anywhere in this server.

### `POST /consent`

Lookup + remove by `consent_token`; unknown → 400. `action=deny` → 302
`redirect_uri?error=access_denied&state=`. `action=allow` → mint auth code
(32 random bytes; store SHA-256 with `clientId, redirectURI,
codeChallenge, resource, sub(email), expiresAt = now + 60 s, used=false`
in `tokens.sqlite`) → 302 `redirect_uri?code=&state=<clientState>&iss=<PUBLIC_URL>`.
Audit `code.issued`.

### `POST /token` (form-urlencoded; JSON responses with `Cache-Control: no-store`, `Pragma: no-cache`)

Common: `client_id` must equal the configured one → else `401
invalid_client`. Optional client-secret hook as above.

`grant_type=authorization_code`: lookup code by hash; missing/expired →
`400 invalid_grant`; **already used → revoke every token family that code
produced (RFC 6749 §4.1.2), audit `code.reuse`, `invalid_grant`**;
`redirect_uri` must equal the stored one; PKCE:
`base64url(SHA256(code_verifier)) == stored challenge` (constant-time);
`resource`, if present, must equal stored. Success: new family; access
token (32 random bytes, 15 min) + refresh token (32 bytes; idle 14 d,
absolute 30 d from family creation); DB stores SHA-256 only, plus
`aud = resourceURL, client_id, sub, family_id`. Response
`{access_token, token_type:"Bearer", expires_in:900, refresh_token, scope:"vault:read"}`.
Audit `token.issued{family}`.

`grant_type=refresh_token`: lookup by hash. Not found → `invalid_grant`.
Found but `superseded_at != nil` → **reuse**: revoke the whole family
(every access + refresh token), audit `refresh.reuse{family}`,
`invalid_grant`. Family revoked, idle > 14 d since `issued_at`, or
`now > family.absolute_expiry` → `invalid_grant`. `client_id` ≠ family's
→ `invalid_grant`. Else rotate: mark old `superseded_at = now`, issue new
access + refresh in the same family (absolute expiry inherited), audit
`refresh.rotated`. Response as above.

Errors use RFC 6749 §5.2 codes (`invalid_request`, `invalid_client`,
`invalid_grant`, `unsupported_grant_type`, `invalid_target`).

### `POST /revoke` (RFC 7009)

`token` (+ optional `token_type_hint`): refresh → revoke family; access →
revoke that token; unknown → still `200`. Audit `revoke`.

### `TokenAuthenticator: BearerAuthenticator` (replaces `DenyAll` in `main.swift`)

Parse `Authorization: Bearer <t>` (exactly one space; token charset
b64url); hash; lookup access token: must exist, `revoked_at == nil`,
`expires_at > now`, family not revoked, `aud == resourceURL`, `client_id`
== configured → `.allowed(Principal{sub, clientId, familyId})`; every
other case → `.denied(.invalidToken)` → 06's 401 with
`error="invalid_token"`. Missing header → `.denied(.missing)`. Update
`last_used_at` on the token (one UPDATE; fine at this scale).

### Token store — `STATE_DIR/tokens.sqlite` (GRDB, WAL, file mode 0600)

```
family(id TEXT PK, client_id, sub, created_at, absolute_expiry, revoked_at, revoke_reason)
token(hash TEXT PK, family_id, kind 'access'|'refresh', issued_at, expires_at, superseded_at, revoked_at, last_used_at)
auth_code(hash TEXT PK, client_id, redirect_uri, code_challenge, resource, sub, expires_at, used_at, family_id)
```
Hourly housekeeping deletes rows expired > 24 h. `kill` (06) deletes the
file.

### Rate limits and audit (adds to 06's limiter)

Per client IP when `NR_TRUST_FORWARDED_FOR=1`, otherwise one global
bucket: `/authorize`, `/auth/google/callback`, `/consent`, `/token`,
`/revoke` → 10/min each → `429` + `Retry-After`, audit `auth.ratelimited`.
Audit events added: `authorize.rejected{reason}`, `authorize.no_resource`,
`login.ok`, `login.denied`, `consent.denied`, `code.issued`, `code.reuse`,
`token.issued`, `refresh.rotated`, `refresh.reuse`, `revoke`. **Never
logged**: any token, code, verifier, nonce, state, Google secret, full
foreign email.

### Randomness and comparisons

All secrets from `SystemRandomNumberGenerator` (32 bytes → base64url, no
padding). Equality of secrets (client_id, PKCE, client-secret hook) via a
constant-time compare helper; hash lookups are by SQLite equality on the
SHA-256, which leaks nothing useful (document this in a comment).

### `scripts/remote-vault/oauth-probe.sh` (bash + curl + openssl; no python)

Usage: `oauth-probe.sh <PUBLIC_URL> <client_id>`. Generates a PKCE verifier
and `state`, prints the `/authorize` URL with
`redirect_uri=http://127.0.0.1:8765/cb`, listens once on 8765 with `nc -l`
for the callback (or asks the user to paste the redirected URL if `nc` is
unavailable), exchanges the code at `/token`, calls `/mcp` `initialize` +
`tools/list` + `tools/call vault_overview`, then refreshes once, then
**reuses the old refresh token and expects `invalid_grant`**, then shows
the access token now gets 401 (family revoked). Tokens are kept in a
`mktemp` file deleted on exit; nothing is printed except the last 4 chars.

## Tests — `Tests/RemoteServerCoreTests/OAuth*` (Swift Testing; macOS gate + Linux CI)

`FakeGoogle`: an in-process Hummingbird app on a loopback port serving
`/.well-known/openid-configuration`, `/o/oauth2/v2/auth` (records the
request, 302s back to our callback with a code), `/token` (returns an
`id_token` signed with a test RSA-2048 key generated by `_CryptoExtras`;
the test controls every claim), `/certs` (JWKS with that key; a second
`kid` to test refetch). Clock and TTLs are injected.

1. **Metadata**: both discovery paths return the document above;
   `registration_endpoint` absent; `code_challenge_methods_supported ==
   ["S256"]`; PRM (06) `authorization_servers == [issuer]`.
2. **/authorize**: wrong `client_id` → 400 page, no `Location`; wrong
   `redirect_uri` (including `https://claude.ai/api/mcp/auth_callback/`
   with a trailing slash, a different host, `http://127.0.0.1:1/cb` while
   loopback off) → 400 page; loopback on → accepted; `plain` method /
   missing challenge / missing state → 302 with `error=invalid_request` +
   `state`; `resource=https://evil/mcp` → `invalid_target`; `resource`
   absent → accepted + audit `authorize.no_resource`; valid → 302 to the
   fake Google with `nonce`, `state`, `code_challenge_method=S256`,
   `scope=openid email`.
3. **Callback**: unknown `state` → 400; expired pending (clock +11 min) →
   400; fake Google returns `email=other@example.com` → 403 + audit
   `login.denied` whose line contains no `other@example.com` substring;
   `email_verified=false` → 403; wrong `nonce` → 403; wrong `aud` → 403;
   expired `exp` → 403; signature by an unknown key → 403 (after one JWKS
   refetch — assert the fake's `/certs` hit count == 2); `alg=none` → 403;
   `RCHAIGHT@Gmail.com` (case) → consent page; consent page HTML contains
   the redirect host (`claude.ai` or `127.0.0.1`).
4. **Consent**: allow → 302 with `code`, `state == original`, `iss`; the
   `consent_token` reused → 400; deny → `error=access_denied`; pending
   store caps at 100 (101st evicts the oldest, which then fails as
   unknown).
5. **/token (code)**: PKCE verifier mismatch → `invalid_grant`;
   `redirect_uri` mismatch → `invalid_grant`; `client_id` mismatch → 401
   `invalid_client`; code after 61 s → `invalid_grant`; **code reused →
   `invalid_grant` and the tokens from the first exchange are now rejected
   by `TokenAuthenticator`**, audit `code.reuse`; happy path returns
   `expires_in == 900`, both tokens 43 chars b64url; response headers
   `Cache-Control: no-store`.
6. **/token (refresh)**: rotation returns a new pair and the old refresh
   token is superseded; **old refresh reused → `invalid_grant`, audit
   `refresh.reuse`, AND the new access token from the rotation is now
   401** (family revoked); idle 14 d + 1 s → `invalid_grant`; absolute 30 d
   after family creation, even with daily use → `invalid_grant`; refresh
   with the other `client_id` → `invalid_grant`; unknown token →
   `invalid_grant`.
7. **Bearer**: no header → 401 + exact `WWW-Authenticate` (06's);
   `Bearer` + garbage → 401 `invalid_token`; expired (clock +16 min) → 401;
   revoked → 401; wrong-aud token planted in the DB → 401; valid →
   `tools/list` 200 and `tools/call read_note` returns the fixture note;
   `last_used_at` updated.
8. **/revoke**: refresh → family dead (access 401); access → that token
   401, refresh still rotates; unknown → 200.
9. **Rate limit**: 11th `/token` within a minute (same IP via
   `X-Forwarded-For` with `NR_TRUST_FORWARDED_FOR=1`) → 429; a different
   forwarded IP is unaffected; with the flag off the limit is global.
10. **Audit hygiene**: run the whole happy path + every failure, collect
    every secret the test minted (codes, tokens, verifiers, nonces, states,
    the Google secret) and assert none appears as a substring anywhere in
    the audit file.
11. **Client-secret hook**: with `NR_OAUTH_CLIENT_SECRET_SHA256` set,
    `/token` without the secret → `invalid_client`; with it (both `post`
    and `basic`) → ok; metadata advertises the two methods.
12. **Store**: file mode 0600 (skip on Windows — n/a); housekeeping removes
    expired rows; `kill` plan includes deleting the file.
13. **Probe script**: `bash -n` and `shellcheck` (if installed) clean; a
    test runs it end-to-end against the in-process server + fake Google
    with `nc` available (skip with a message when `nc` is missing), asserting
    its exit code 0 and that its final line reports "reuse detected:
    invalid_grant; family revoked: 401".

## Acceptance criteria

1. Tests 1–13 green on macOS (gate 3×) and on the Linux CI job (link).
2. `grep -rn "registration\|/register" Packages/RemoteServer/Sources` →
   only comments saying there is none.
3. `grep -rn "print(\|debugPrint" Packages/RemoteServer/Sources/RemoteServerCore/OAuth` → nothing
   (no accidental secret printing; use the audit log and `Logger`).
4. The Google client secret is read from the environment once at startup
   and held in a `struct` that is not `CustomStringConvertible`; `status`
   masks it.
5. Stage 1 (user, after 08): `oauth-probe.sh https://<node>.<tailnet>.ts.net <client_id>`
   completes with exit 0 from the Mac on the tailnet (Google login in the
   browser, `NR_ALLOW_LOOPBACK=1`); MCP Inspector connects with the typed
   client ID and lists 7 tools; the audit log shows `login.ok`,
   `code.issued`, `token.issued`, `refresh.rotated`, `refresh.reuse`, and
   no `login.denied`. Logging in with a second Google account (the user
   has one, or uses a browser profile without rchaight@gmail.com) yields
   the 403 page and one `login.denied`.
6. Stage 2 (user): `NR_ALLOW_LOOPBACK=0`; claude.ai custom connector with
   URL `<PUBLIC_URL>/mcp` and the client ID connects; a chat call to
   `vault_overview` works; the phone app works; a 16-minute idle gap
   followed by a tool call succeeds (refresh path) with `refresh.rotated`
   in the log.

## Files expected to change

- new `Packages/RemoteServer/Sources/RemoteServerCore/OAuth/{Metadata,Authorize,GoogleOIDC,JWKS,Consent,Token,Revoke,TokenAuthenticator,PendingStore}.swift`
- new `Packages/RemoteServer/Sources/RemoteServerCore/Store/TokenStore.swift`
- `Packages/RemoteServer/Sources/RemoteServerCore/Config/RemoteConfig.swift` (validation of OAuth keys), `HTTP/App.swift` (routes), `HTTP/RateLimiter.swift` (auth buckets), `Audit/AuditLog.swift` (events), `CLI/Commands.swift` (`status` warning)
- `Packages/RemoteServer/Sources/notetaker-remote/main.swift` (wire `TokenAuthenticator`)
- `Packages/RemoteServer/Package.swift` (`_CryptoExtras` product; nothing else new)
- new `Packages/RemoteServer/Tests/RemoteServerCoreTests/OAuth*.swift`, `FakeGoogle.swift`
- new `scripts/remote-vault/oauth-probe.sh`
- `PROGRESS.md` (one row)

Must not change: 06's router contract beyond adding routes, `ToolGateway`,
`ReplicaWatcher`, MCPKit, any App file, docs other than PROGRESS.

## Non-goals

- Dynamic client registration, CIMD, multiple clients, multiple users,
  scopes beyond `vault:read`, JWT access tokens, introspection (RFC 7662),
  device flow, sessions/cookies, "remember this device".
- Keycloak/Pomerium/Hydra (design §4.4 verdict).
- Holding Google refresh tokens (none requested: `access_type=online`,
  scope `openid email` only).

## Verification commands

```bash
cd ~/Developer/Notetaker/Packages/RemoteServer && DEVELOPER_DIR=/Applications/Xcode.app \
  swift test --scratch-path ~/.cache/notetaker-build/RemoteServer --filter OAuth
bash -n scripts/remote-vault/oauth-probe.sh && (command -v shellcheck && shellcheck scripts/remote-vault/oauth-probe.sh || true)
cd ~/Developer/Notetaker && swiftformat --lint . && scripts/verify.sh 3 --install   # exit code captured directly
git push -u origin HEAD && gh pr create --draft --title "OAuth AS (spec 07)" --body "CI only." && gh run watch
```

## Builder notes

**opus.** This is the security-critical state machine. Write the token
store and `TokenAuthenticator` first with their tests, then the flow. Do
not weaken a check to make a test pass; if Claude's real behaviour (stage
2) needs tolerance beyond `resource`-absent, add a flag, a test, and a
PROGRESS note — never a silent relaxation. Read `HTTPRequestValidation.swift`'s
`BearerTokenValidator` in the SDK for the 401 conventions it expects, but
keep our own authenticator (the SDK validator runs inside the transport,
after our middleware; we want the decision before the body is parsed).
