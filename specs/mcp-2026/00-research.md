# MCP 2026-07-28 in `notetaker-remote` — research (read-only phase)

Date: 2026-10-31. Scope: what the 2026-07-28 revision requires of a minimal, read-only, tools-only Streamable HTTP server; what it means for our OAuth server; where upstream stands; where each behaviour plugs into our code; the design choice. Nothing here has been run against the live container; section (h) lists what only a live capture can settle.

Sources are cited inline. Spec pages were fetched as Markdown from `modelcontextprotocol.io/specification/2026-07-28/…` on 2026-10-31; JSON examples are quoted verbatim from those pages. Anything marked **[unverified]** or **[judgement]** is exactly that.

---

## (a) Executive summary and go/no-go

**What is true today.** Anthropic's clients (Duet and, by the PROGRESS row 220/221 capture, at least one other Claude surface) open with `server/discover` under `MCP-Protocol-Version: 2026-07-28`. Our server runs swift-sdk 0.12.1, whose `ProtocolVersionValidator` answers any unknown header value with HTTP 400 and the body `{"jsonrpc":"2.0","error":{"code":-32600,"message":"Bad Request: Unsupported protocol version: 2026-07-28. Supported: 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25"},"id":null}`. Per the 2026 transport page a client that receives a 400 whose body is **not** a recognised modern error (`-32020`, `-32021`, `-32022`) falls back to `initialize` — which is exactly the fallback we fixed in `afb6031`. So we work by being correctly identified as a *legacy* server, and the legacy era is still a first-class, fully specified path ("Legacy client → Dual-era server: works"; "Dual-era client → Legacy server: works", [versioning compatibility matrix](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning#compatibility-matrix)).

**What is not known.** No Anthropic document states a sunset for the `initialize` fallback. The [Anthropic announcement](https://claude.com/blog/bringing-mcp-2026-07-28-to-claude) (2026-07-28) says only "Support is being rolled out across Claude products" and names no clients, no fallback policy and no dates. The spec's deprecation policy applies to *features*, and the legacy handshake is not in the [deprecated registry](https://modelcontextprotocol.io/specification/2026-07-28/deprecated); only Roots, Sampling, Logging, DCR, HTTP+SSE and two `includeContext` values are. There is therefore no spec-level date by which legacy-only servers stop working, and no Anthropic date either.

**Upstream.** swift-sdk has no release with 2026 support (newest 0.12.1, 2026-05-07). A 23-file community PR ([#314](https://github.com/modelcontextprotocol/swift-sdk/pull/314), opened 2026-10-25) implements a dual-era profile but has zero reviews and zero comments, and the three smaller prerequisites ([#288](https://github.com/modelcontextprotocol/swift-sdk/pull/288) client headers, [#290](https://github.com/modelcontextprotocol/swift-sdk/pull/290) `ttlMs`/`cacheScope`, [#291](https://github.com/modelcontextprotocol/swift-sdk/pull/291) error `data`) have sat unmerged since 2026-09-24 while maintainers merged five unrelated PRs on 2026-10-31. The 17 tracker issues for the 2026 SEPs (#230–#247) have been open since 2026-06-06. TypeScript (2.4.0) and Python (2.3.0) SDKs ship dual-era servers today.

**Recommendation: GO on option A (modern-path router in front of the SDK), as a bounded shakedown item, not an emergency.** Reasons: (1) it is ~300 lines of our own code plus tests, with no new public route and no new tool, so it is not a security change under the project gate (the design doc still gets a dated note); (2) it removes a dependence on client fallback behaviour that Anthropic has never promised; (3) it makes the server a textbook "dual-era server" per the spec, which is the shape every other SDK has converged on; (4) waiting on swift-sdk (option B) is unbounded and PR 314, even if merged, does not implement `Mcp-Method`/`Mcp-Name` validation and returns a non-conformant 400 for `subscriptions/listen` on the stateless transport. Ordering: the backup host steps (spec `vault-backup/00`) are independent and should not be displaced; do the live capture (section h) first because it determines two open shapes (`subscriptions/listen`, `ping` in modern mode) that the build spec must fix before a Sonnet builder starts.

---

## (b) Methods and responses a minimal read-only tools-only server must implement in 2026-07-28 mode

### Era classification (decides which path serves the request)

The [versioning page](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning#backward-compatibility-with-initialization-based-versions): "A dual-era **server** selects its behavior from how the client opens: A request carrying modern per-request `_meta` is served statelessly according to this revision. An `initialize` request selects legacy semantics". The TypeScript SDK's [`protocolEras.ts`](https://github.com/modelcontextprotocol/typescript-sdk/blob/main/packages/core-internal/src/shared/protocolEras.ts) adds the rule "`initialize` never accepts or counter-offers a modern revision", and swift-sdk PR 314's `JSONRPCMessageKind.isModernProfile` classifies a request as modern when it is `server/discover`/`subscriptions/listen`, or when `params._meta["io.modelcontextprotocol/protocolVersion"]` is a modern version, or (notifications/responses only) when the header is modern.

Proposed rule for our router (matches both SDKs):

| Condition | Era |
|---|---|
| `method == "initialize"` | legacy, always (current `initializeReply`) — even with a 2026 header |
| `method == "server/discover"` | modern |
| `params._meta["io.modelcontextprotocol/protocolVersion"]` present and `>= "2026-07-28"` (ISO dates compare lexically) | modern |
| `MCP-Protocol-Version` header `>= "2026-07-28"` and body is a JSON-RPC request | modern (and then fails validation, see table rows V2/V5) |
| otherwise (no `_meta` version, header absent or legacy) | legacy → SDK path, unchanged |

Notifications (no `id`) keep today's behaviour (SDK yields, 202). The 2026 core "defines no client-to-server notifications over Streamable HTTP"; a `notifications/initialized` from a legacy client is still legal on the legacy path.

### Per-request `_meta` (base protocol)

From [basic/index#meta](https://modelcontextprotocol.io/specification/2026-07-28/basic/index#meta):

| Key | Required | Server duty |
|---|---|---|
| `io.modelcontextprotocol/protocolVersion` | **Yes** | must equal the `MCP-Protocol-Version` header; unknown version → `-32022` |
| `io.modelcontextprotocol/clientCapabilities` | **Yes** | "A server MUST NOT rely on capabilities the client has not declared" — we need none, so accept `{}` and ignore |
| `io.modelcontextprotocol/clientInfo` | No | display/logging only; "SHOULD NOT … rely on it for security decisions" |
| `io.modelcontextprotocol/logLevel` | No | "servers MUST NOT emit `notifications/message` for requests that did not include this field" — we emit none, ignore |

"A request missing any required field is malformed; the server **MUST** reject it with JSON-RPC error code `-32602` (Invalid params). On HTTP, the response status **MUST** be `400 Bad Request`." Results: "Servers **SHOULD** include … `io.modelcontextprotocol/serverInfo` in every result's `_meta`"; every result carries required `resultType` (`"complete"` here; `"input_required"` is the MRTR interim result we never produce) — [schema `Result`](https://modelcontextprotocol.io/specification/2026-07-28/schema#result), [changelog item 8](https://modelcontextprotocol.io/specification/2026-07-28/changelog).

### HTTP header rules ([streamable-http#request-metadata](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#request-metadata))

- `MCP-Protocol-Version` — "Every POST request to the MCP endpoint MUST include" it; "MUST match the `io.modelcontextprotocol/protocolVersion` field … If the values do not match, the server MUST reject the request with `400 Bad Request` and a `HeaderMismatch` JSON-RPC error".
- `Mcp-Method` — required on **all** requests, value = body `method`.
- `Mcp-Name` — required on `tools/call` (= `params.name`), `resources/read` (= `params.uri`), `prompts/get`. Not listed for `tools/list` or `server/discover`.
- Base64 sentinel: a value that cannot be plain ASCII is sent as `Mcp-Name: =?base64?{Base64EncodedValue}?=`; markers are lowercase and case-sensitive; "servers **MUST** decode an encoded `Mcp-Name` … value before comparing it to the corresponding request body value"; a plain value that itself matches the sentinel pattern is also encoded by the client. Our seven tool names are plain ASCII, but a conformant client may still encode, so decode before comparing.
- Header names case-insensitive, values case-sensitive ([#case-sensitivity](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#case-sensitivity)).
- Validation failure → `400` + `-32020`. "Validation failure conditions include: A required standard header (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`) is missing. A header value does not match the corresponding request body value … A header value contains invalid characters."
- `Mcp-Param-*`: only for parameters a server annotates with `x-mcp-header`; none of our seven schemas does (grep of `Packages/MCPKit/Sources` is empty), so no `Mcp-Param-*` header is "recognized" and the server ignores them. **[judgement]** The build spec should assert no `x-mcp-header` key appears in any advertised `inputSchema`, because once one does, clients MUST mirror it and the server MUST validate it.
- Unknown method → "`404 Not Found` and a JSON-RPC error with code `-32601`" ([#protocol-version-header](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#protocol-version-header)).
- Unsupported version → "`400 Bad Request` and an `UnsupportedProtocolVersionError` listing its supported versions".
- Older-client traffic ([#earlier-streamable-http-revisions](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#earlier-streamable-http-revisions)): "HTTP GET or DELETE to the MCP endpoint: respond with `405 Method Not Allowed`. An `Mcp-Session-Id` header on a request: ignore it, and do not mint or echo session IDs. A `Last-Event-ID` header: ignore it".
- `Accept`: the client "MUST include an `Accept` header listing both `application/json` and `text/event-stream`"; the server "MUST return either `Content-Type: application/json` (a single JSON object) or `Content-Type: text/event-stream`". We answer `application/json` only, which is allowed; our existing `AcceptHeaderValidator(mode: .jsonOnly)` requires `application/json` to be present, which a 2026 client satisfies.
- Origin: "If the `Origin` header is present and invalid, servers MUST respond with HTTP 403" — our Host allowlist (421) plus bearer auth is the existing control; unchanged by this work.

### The request/response table

Every modern request below carries the standard `_meta` (shown once in D1) and the headers in the "Headers" column; `serverInfo` values are ours (`NotetakerMCPServer.serverName` = `"notetaker"`, `NotetakerMCPServer.version`).

| # | Request (method, headers) | Response (status, body) | Spec |
|---|---|---|---|
| D1 | `server/discover` — `MCP-Protocol-Version: 2026-07-28`, `Mcp-Method: server/discover`. Body: `{"jsonrpc":"2.0","id":"discover-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"ExampleClient","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}` | `200` `{"jsonrpc":"2.0","id":"discover-1","result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{"listChanged":false}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"notetaker","version":"<v>"}},"instructions":"<RemoteToolCatalog.instructions>","ttlMs":3600000,"cacheScope":"private"}}` | [server/discover](https://modelcontextprotocol.io/specification/2026-07-28/server/discover) ("Servers **MUST** implement it"); `DiscoverResult` fields `resultType, supportedVersions, capabilities, instructions?, ttlMs, cacheScope` ([schema](https://modelcontextprotocol.io/specification/2026-07-28/schema#discoverresult)); caching hints are mandatory on discover ([caching](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching#cacheable-results)) |
| L1 | `tools/list` — `MCP-Protocol-Version: 2026-07-28`, `Mcp-Method: tools/list`. Body `params` = `{"_meta":{…}}` (optional `cursor`) | `200` `{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[<the seven Tool objects, same JSON as today, fixed order>],"ttlMs":3600000,"cacheScope":"private","_meta":{"io.modelcontextprotocol/serverInfo":{…}}}}` — no `nextCursor` (single page). A `cursor` we did not mint → `-32602` ("Pagination: Invalid or expired cursor values") | [tools#listing-tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools#listing-tools); `ListToolsResult` requires `ttlMs` and `cacheScope` ([schema](https://modelcontextprotocol.io/specification/2026-07-28/schema#listtoolsresult)); "Servers **SHOULD** return tools in a deterministic order"; the set "MUST NOT vary per-connection" |
| C1 | `tools/call` — `MCP-Protocol-Version: 2026-07-28`, `Mcp-Method: tools/call`, `Mcp-Name: read_note`. Body `params` = `{"name":"read_note","arguments":{"path":"Inbox.md"},"_meta":{…}}` | `200` `{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","content":[{"type":"text","text":"<framed>"}],"structuredContent":{…},"isError":false,"_meta":{"io.modelcontextprotocol/serverInfo":{…}}}}` — the `ToolGateway` result exactly as today plus `resultType` and `_meta` | [tools#calling-tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools#calling-tools); `CallToolResult` ([schema](https://modelcontextprotocol.io/specification/2026-07-28/schema#calltoolresult)) |
| C2 | `tools/call` with the gateway's `isError` result (unknown tool, clamp failure, timeout, oversize) | `200`, same shape with `"isError":true` — unchanged gateway behaviour; audit line written | Spec prefers `-32602` for "Unknown tool name" ([InvalidParamsError](https://modelcontextprotocol.io/specification/2026-07-28/schema#invalidparamserror)); SDKs disagree ([python-sdk #3659](https://github.com/modelcontextprotocol/python-sdk/issues/3659)). **[judgement]** keep the gateway's result so the era does not fork behaviour; record as a known deviation |
| V1 | Any modern request whose `_meta` version is not one we implement (e.g. `"2026-12-01"`, `"1900-01-01"`), header equal to it | `400` `{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2026-07-28"],"requested":"1900-01-01"}}}` | [versioning#protocol-version-negotiation](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning#protocol-version-negotiation); `UnsupportedProtocolVersionError` `data: { supported: string[]; requested: string }` ([schema](https://modelcontextprotocol.io/specification/2026-07-28/schema#unsupportedprotocolversionerror)). The spec example lists `["2026-07-28","2025-11-25"]`; **[judgement]** list only modern versions, since "The client should choose one of these for subsequent requests" and we cannot serve a legacy version in modern shape (TypeScript SDK does the same) |
| V2 | Header `2026-07-28`, body `_meta` version `2025-11-25` (or any differing value) | `400` `{"jsonrpc":"2.0","id":1,"error":{"code":-32020,"message":"Header mismatch: MCP-Protocol-Version header value '2026-07-28' does not match body value '2025-11-25'"}}` | [#server-validation](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#server-validation); `HeaderMismatchError` ([schema](https://modelcontextprotocol.io/specification/2026-07-28/schema#headermismatcherror)) |
| V3 | Modern request with `Mcp-Method` missing, or not equal to body `method` | `400` `-32020` as V2, message names the header | same |
| V4 | `tools/call` with `Mcp-Name` missing, or (after sentinel decoding) not equal to `params.name`, or containing invalid characters | `400` `-32020` | same; [#value-encoding](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#value-encoding) |
| V5 | Body carries modern `_meta` but `MCP-Protocol-Version` header absent | `400` `-32020` ("required standard header … is missing") | same. (A header-less request *without* modern `_meta` stays legacy and is allowed: "A server that supports clients implementing protocol versions earlier than `2025-06-18` … MAY treat a request that omits the header as protocol version `2025-03-26`") |
| V6 | Modern-classified request (by header or method) whose `_meta` lacks `io.modelcontextprotocol/protocolVersion` or `io.modelcontextprotocol/clientCapabilities` | `400` `{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params: _meta.io.modelcontextprotocol/clientCapabilities is required"}}` | [basic/index#meta](https://modelcontextprotocol.io/specification/2026-07-28/basic/index#meta) "MUST reject it with … `-32602` … status MUST be `400`" |
| U1 | Modern request for any method we do not implement: `resources/list`, `prompts/list`, `ping`, `logging/setLevel`, `resources/subscribe`, `completion/complete`, `tasks/*`, and `initialize` is *not* here (always legacy) | `404` `{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}` | [#protocol-version-header](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#protocol-version-header); `MethodNotFoundError` covers "a method … gated behind a server capability the server did not advertise" ([schema](https://modelcontextprotocol.io/specification/2026-07-28/schema#methodnotfounderror)); `ping` and `logging/setLevel` were removed ([changelog 5](https://modelcontextprotocol.io/specification/2026-07-28/changelog)) |
| U2 | `subscriptions/listen` (modern) | **[judgement]** `404` `-32601` as U1 — see the note below | [subscriptions](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions) |
| T1 | `GET`, `DELETE`, `PUT`, `PATCH /mcp` | `405`, `Allow: POST` (already: `App.swift` 36–42 and the SDK transport) | [#earlier-streamable-http-revisions](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#earlier-streamable-http-revisions) |
| T2 | Any request carrying `Mcp-Session-Id` or `Last-Event-ID` | ignored; never minted or echoed (already true: stateless transport has no `SessionValidator`) | same |
| T3 | Modern POST whose body is a JSON-RPC *notification* | `202`, empty body (today's SDK behaviour via `incomingContinuation.yield`) | [#sending-messages](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#sending-messages) |
| T4 | `Accept` without `application/json` | `406` (existing validator; keep for the modern path) | [#sending-messages] requires both types from the client; the server's 406 is implementation-defined |
| I1 | `initialize` (any header, any `protocolVersion`) | `200`, today's `initializeReply`: echoes a legacy version we support else `"2025-11-25"`; `capabilities`, `serverInfo`, `instructions` | [versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning#backward-compatibility-with-initialization-based-versions) "An `initialize` request selects legacy semantics"; "A server that supports only modern versions SHOULD name the protocol versions it supports in any error it returns to an `initialize` request" (not our case) |

**On `subscriptions/listen` (U2).** I could not find a MUST that a server implement it. The subscriptions page specifies it in client terms ("The client sends a `subscriptions/listen` request… The server MUST NOT send notification types the client has not explicitly requested"); the changelog says it "replace[s] the HTTP GET endpoint and `resources/subscribe`"; the [caching page](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching#interaction-with-notifications) says "A server **MAY** provide `ttlMs` without advertising `listChanged: true` … the client relies entirely on TTL-based freshness"; `ServerCapabilities` has no `subscriptions` field, only `tools.listChanged`, `prompts.listChanged`, `resources.subscribe/listChanged` ([schema](https://modelcontextprotocol.io/specification/2026-07-28/schema#servercapabilities)). A server advertising `tools: {listChanged: false}` and no resources/prompts therefore has nothing a listen stream could ever carry. `404 -32601` ("a method gated behind a server capability the server did not advertise") is the spec-consistent answer. swift-sdk PR 314 answers `400 -32600 "subscriptions/listen requires a streaming (stateful) HTTP transport"` on its stateless transport — that is *not* a recognised modern error and would make a client fall back, so do not copy it. Whether Claude's clients send `subscriptions/listen` at all, and how they react to a 404, is live-capture question H3.

### Deprecated / removed — what we must NOT implement

[Deprecated registry](https://modelcontextprotocol.io/specification/2026-07-28/deprecated): Roots, Sampling, Logging (earliest removal "First revision released on or after 2027-07-28"), Dynamic Client Registration (same), `includeContext` values, HTTP+SSE transport. Removed outright in this revision ([changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)): `initialize`/`notifications/initialized` (modern), `Mcp-Session-Id`, the GET SSE endpoint, `resources/subscribe`/`unsubscribe`, `ping`, `logging/setLevel`, `notifications/roots/list_changed`, SSE resumability/`Last-Event-ID`, server-initiated JSON-RPC requests on streams (replaced by MRTR), `tasks/*` in core, `notifications/elicitation/complete`, error `-32002`. For us: declare only `tools`; never `logging`; no `ping` handler in modern mode; never emit `-32002`; never emit any `-32020…-32099` code other than the three defined.

---

## (c) Authorization findings

What each 2026 change is, and what it means for `/authorize`, `/token`, the two metadata documents, and the seven-route gate. **None of them needs a new public route.** The one item that would be a security change (CIMD) is flagged at the end.

### 1. `iss` in authorization responses (RFC 9207, SEP-2468)

Spec ([authorization#authorization-response-validation](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/index#authorization-response-validation)): "MCP authorization servers **SHOULD** include the `iss` parameter in authorization responses, including error responses … Authorization servers that include the `iss` parameter **MUST** advertise this by setting `authorization_response_iss_parameter_supported` to `true`". Client side: "clients **MUST** apply the validation in RFC9207 Section 2.4 before transmitting the authorization code"; with the flag `true`, a *missing* `iss` is rejected; comparison is "simple string comparison" with "no scheme or host case folding, default-port elision, trailing-slash, or percent-encoding normalization"; "This validation applies equally to error responses". "A future revision … is expected to upgrade … from SHOULD to MUST."

Ours: `Authorize.swift` appends `("iss", settings.issuer)` on protocol-error redirects (line 37), on the Google-cancel redirect (line 112), and on the consent success redirect (asserted in `OAuthConsentTests.swift:23`); `OAuthSettings.metadataDocument` sets `"authorization_response_iss_parameter_supported": true` (line 174, asserted in `OAuthMetadataTests.swift:30`); the value is `config.publicURL`, the same string as the metadata `issuer` (line 164), so byte-identical comparison holds. **Nothing to do**, provided `NR_PUBLIC_URL` never changes form (trailing slash, case) without the metadata changing with it — it is one constant, so it cannot.

### 2. Client ID Metadata Documents vs Dynamic Client Registration (PR #2858, SEP-991)

Spec ([client-registration](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration)): clients "SHOULD use the following priority order: 1. Use pre-registered client information for the server if the client has it available 2. Use Client ID Metadata Documents if the Authorization Server indicates that it supports them (via `client_id_metadata_document_supported`…) 3. Use Dynamic Client Registration as a fallback if … `registration_endpoint` … 4. Prompt the user to enter the client information". DCR "is deprecated … remains available for backwards compatibility". Pre-registration: "MCP clients **SHOULD** support an option for static client credentials … Present a UI to users that allows them to enter these details".

Claude ([claude.com connector auth docs](https://www.claude.com/docs/connectors/building/authentication), fetched 2026-10-31): CIMD is used "only when your authorization server metadata advertises both `client_id_metadata_document_supported: true` and `none` in `token_endpoint_auth_methods_supported`", otherwise DCR; hosted Claude apps (web, Desktop, mobile, Cowork) redirect to `https://claude.ai/api/mcp/auth_callback`; Claude Code uses its own CIMD at `https://claude.ai/oauth/claude-code-client-metadata` with loopback redirects. The page does not mention Duet, `iss`, `application_type`, issuer-keyed credentials, or any MCP protocol version.

Ours: pre-registered single client (design §9), `registration_endpoint` absent and `client_id_metadata_document_supported` absent (both asserted, `OAuthMetadataTests.swift:31-32`; `stage1-check.sh` fails on a `registration_endpoint` and expects `/register` → 404). **A 2026 client still accepts a pre-registered client with a fixed redirect URI** — it is priority 1 in the spec, and it is what claude.ai does today (PROGRESS 221: both claude.ai and Duet connected after `afb6031`). **Nothing to do.** Claude Code remains unsupported by design (it needs CIMD or loopback redirects; `NR_ALLOW_LOOPBACK` exists only for the stage-1 drill).

### 3. `application_type` (SEP-837)

"MCP clients **MUST** specify an appropriate `application_type` during Dynamic Client Registration" ([client-registration#application-type-and-redirect-uri-constraints](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration#application-type-and-redirect-uri-constraints)). A DCR-only, client-side rule. We have no `/register`. **Not applicable.**

### 4. Issuer-keyed credentials / authorization server binding (SEP-2352)

"Clients that use pre-registered credentials … **MUST** associate those credentials with the specific authorization server that issued them, keyed by the authorization server's `issuer` identifier … If the authorization server indicated by protected resource metadata no longer matches … clients **SHOULD** surface an error". Client-side. Operational consequence for us: the PRM's `authorization_servers[0]` and the AS `issuer` must stay the same string across deploys (they are both `config.publicURL`); renaming the Tailscale node changes the issuer and the user will have to re-add the connector. **No code change**; worth one line in the RUNBOOK.

### 5. Protected-resource metadata and AS discovery (SEP-2351 and friends)

[authorization-server-discovery](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/authorization-server-discovery): PRM "MUST" (RFC 9728), served at the endpoint path (`/.well-known/oauth-protected-resource/mcp`) or root — we serve both (`App.swift` 44–56; `stage1-check.sh` checks both). Clients try `/.well-known/oauth-authorization-server` then `/.well-known/openid-configuration` for a path-less issuer — we serve both. "the `issuer` value in the document **MUST** be identical to the issuer identifier used to construct the well-known URL" — ours is. `resource` canonical-URI rules unchanged (`Token.swift` 137–143 enforces `resource == settings.resourceURL`). **Nothing to do.**

### Flagged separately: what WOULD be a security change

- **CIMD support** would add no route but would make the AS fetch arbitrary attacker-chosen HTTPS URLs (`client_id` is a URL) and open outbound 443 beyond Google in the CT's nftables (design §4.7). Not needed for claude.ai/Duet; recommend recording "no CIMD" alongside "no DCR" in design §9.
- **DCR** needs `/register` — explicitly rejected (design §9, `stage1-check.sh`).
- The seven public routes stay exactly `/mcp`, `/.well-known/*`, `/authorize`, `/auth/google/callback`, `/consent`, `/token`, `/revoke`; **this work touches only `/mcp`'s body handling.**

---

## (d) Upstream status (as of 2026-10-31)

**swift-sdk** (`gh api repos/modelcontextprotocol/swift-sdk/releases`): 0.12.1 (2026-05-07), 0.12.0 (03-24), 0.11.0 (02-19). `Version.supported` = `2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05`; `latest = "2025-11-25"` (`Sources/MCP/Base/Versioning.swift`, checkout `a0ae212`). No 2026 release announced.

| Item | State | Note |
|---|---|---|
| [PR #314](https://github.com/modelcontextprotocol/swift-sdk/pull/314) "feat: dual-era MCP 2026-07-28 modern protocol profile" (romanbsd) | open since 2026-10-25, 23 files, +2009/−128, **0 reviews, 0 comments**, mergeable | adds `server/discover`, `ProtocolMetaKey`, `ResultType`, `-32022` with `data`, `Version.modern/legacy`, header-vs-body version check (as `-32600`, not `-32020`), `subscriptions/listen` on the **stateful** transport; stateless transport answers `listen` with `400 -32600`; **no `Mcp-Method`/`Mcp-Name` validation, no `-32020`**; `Discover.Result` defaults `cacheScope: .private, ttlMs: 0` |
| [PR #288](https://github.com/modelcontextprotocol/swift-sdk/pull/288) client sends `Mcp-Method`/`Mcp-Name` | open since 2026-09-24 | client-side only |
| [PR #290](https://github.com/modelcontextprotocol/swift-sdk/pull/290) `ttlMs`/`cacheScope` on list results | open since 2026-09-24 | "a wire-model step … not full 2026 support" |
| [PR #291](https://github.com/modelcontextprotocol/swift-sdk/pull/291) preserve error `data` | open since 2026-09-24 | prerequisite for #245 |
| [#245](https://github.com/modelcontextprotocol/swift-sdk/issues/245) SEP-2575 stateless, [#244](https://github.com/modelcontextprotocol/swift-sdk/issues/244), [#246](https://github.com/modelcontextprotocol/swift-sdk/issues/246), [#243](https://github.com/modelcontextprotocol/swift-sdk/issues/243), [#242](https://github.com/modelcontextprotocol/swift-sdk/issues/242) … (17 tracker issues #230–#247) | open since 2026-06-06 | the maintainers' own tracking issues, untouched |
| [#219](https://github.com/modelcontextprotocol/swift-sdk/issues/219) idempotent `initialize` for stateless servers; [PR #257](https://github.com/modelcontextprotocol/swift-sdk/pull/257) | open since 2026-04-19 / 07-12 | the bug we worked around in `afb6031` |
| [#265](https://github.com/modelcontextprotocol/swift-sdk/issues/265) stateless transport keys context by client id (collisions); [PR #264](https://github.com/modelcontextprotocol/swift-sdk/pull/264), [#267](https://github.com/modelcontextprotocol/swift-sdk/pull/267) | open since July | the reason for our `nr-N` id rewrite |
| Branch `feat/intermediate-updates-to-newest-protocol` | 2 commits, 2026-01-16, 26 behind main | abandoned |
| main activity | 5 PRs merged 2026-10-31 (#297, #283, #258, #226, #227) | all unrelated to 2026 |

**TypeScript SDK** 2.4.0 (2026-10-23): one endpoint serves both eras; `protocolEras.ts` splits `SUPPORTED_PROTOCOL_VERSIONS` (legacy, offered by `initialize`) from `SUPPORTED_MODERN_PROTOCOL_VERSIONS = ['2026-07-28']` (advertised by `server/discover`); `server.ts` "installs the modern-only `server/discover` handler on an instance the HTTP entry has marked as serving the 2026-07-28 era … a legacy-only server keeps answering `-32601`"; v2.4.0 notes: "`x-mcp-header` on a `number` parameter is rejected … the server answers a call to it with `-32020`" ([release](https://github.com/modelcontextprotocol/typescript-sdk/releases/tag/v2.4.0)). Open issue [#2873](https://github.com/modelcontextprotocol/typescript-sdk/issues/2873): `subscriptions/listen` streams have no lifetime bound on serverless — evidence that even reference servers struggle with `listen`.

**Python SDK** 2.3.0 (2026-10-02): [docs/run/legacy-clients.md](https://github.com/modelcontextprotocol/python-sdk/blob/main/docs/run/legacy-clients.md): "The SDK routes every request by its `MCP-Protocol-Version` header. A request naming `2026-07-28` goes to the modern handler. A request naming a handshake-era version, or carrying no header at all (which is how a pre-2026 client's `initialize` arrives), goes to the transport those clients expect … Both eras are always on." [docs/protocol-versions.md](https://github.com/modelcontextprotocol/python-sdk/blob/main/docs/protocol-versions.md): the client's default `mode="auto"` "sends a single `server/discover` probe … An older server has never heard of `server/discover` and returns an error. The client falls back to the classic `initialize` handshake". Recent fixes show live 2026 traffic in the wild: [#3767](https://github.com/modelcontextprotocol/python-sdk/issues/3767) (missing `resultType` must default to complete), [#3763](https://github.com/modelcontextprotocol/python-sdk/issues/3763) (whitespace-padded `Mcp-Name`).

**Anthropic.** [Bringing MCP 2026-07-28 to Claude](https://claude.com/blog/bringing-mcp-2026-07-28-to-claude) (2026-07-28): "MCP moves from a bidirectional stateful protocol to a request/response model"; "Support is being rolled out across Claude products"; no client list, no fallback statement, **no sunset**. The connector docs mention no protocol version. Third-party posts claiming "Claude Desktop post-July 28 will call `server/discover` first" are unofficial **[unverified]**. Our own capture (PROGRESS 220/221) is the only hard evidence: Duet sends `server/discover` with `2026-07-28` and falls back.

---

## (e) Code map — where each 2026 behaviour plugs in

All paths under `/Users/rchaight/Developer/Notetaker/Packages/RemoteServer/`.

| Concern | Today | 2026 plug-in point |
|---|---|---|
| Request arrives | `Sources/RemoteServerCore/HTTP/App.swift` `MCPEndpoint.handle` (170–221): 1 authenticate (401 + tarpit) → 2 optional Anthropic IP allowlist → 3 global tool bucket (429) → 4 strip client `x-nr-*`, drop `Authorization`, stamp `X-NR-Client-Id`/`X-NR-Token-Family`/`X-NR-Client-Ip` → `mcp.handle(MCP.HTTPRequest(method:"POST", headers:flattened, body, path:"/mcp"))` → `map` (status + body; `.stream` → 500) | unchanged. Order "auth first" is preserved automatically because the router sits inside `mcp.handle`. `flatten` joins duplicate header lines with `", "` — a duplicated `Mcp-Method` would then mismatch → `-32020`, acceptable |
| 405 for non-POST | `App.swift` 36–42 (router) and SDK `handleRequest` | unchanged; T1 |
| Era routing, `initialize` | `Sources/RemoteServerCore/MCP/RemoteMCPServer.swift` `handle` (91–117): parses body to `[String: Any]`, requires `id` String/NSNumber; `initialize` → `initializeReply` (70–85); else rewrites `id` to `"nr-N"`, calls `transport.handleRequest`, restores the id on `.data` responses only | **insert the classifier between the `initialize` branch (98–100) and the id rewrite (101)**: if modern → `ModernPath.handle(request, message)` (new file `MCP/ModernPath.swift`), return. Modern responses are built by us, so no id rewrite and no SDK waiter — the #265 collision class cannot occur on this path |
| What the SDK does with a 2026 request today | `StatelessHTTPServerTransport.handlePost` → `JSONRPCMessageKind` → `StandardValidationPipeline` [`AcceptHeaderValidator(.jsonOnly)`, `ContentTypeValidator`, `ProtocolVersionValidator`] (`RemoteMCPServer.swift` 48–54). `ProtocolVersionValidator` (`HTTPRequestValidation.swift` 165–192): header present and not in `Version.supported` → `.error(400, .invalidRequest(...))` → body `{"jsonrpc":"2.0","error":{"code":-32600,"message":"Bad Request: Unsupported protocol version: 2026-07-28. Supported: 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25"},"id":null}`. Because the response is `.error`, `handle`'s `guard case .data` skips id restoration (the body has `id: null` anyway). A client reads `-32600` ≠ recognised modern error → falls back to `initialize` | the router answers before the transport; the SDK path keeps serving legacy exactly as now |
| `server/discover` | nothing (400 as above) | `ModernPath`: build `DiscoverResult` from `NotetakerMCPServer.serverName/version`, `RemoteToolCatalog.instructions`, capabilities `{"tools":{"listChanged":false}}` (same literal as `initializeReply` line 76) |
| `tools/list` | SDK `ListTools` handler → `RemoteToolCatalog.tools()` (`RemoteToolCatalog.swift` 28–44), derived from `NotetakerMCPServer.tools()` (an array literal in `Packages/MCPKit/Sources/MCPKit/NotetakerMCPServer.swift` 44–230 → deterministic order) | `ModernPath`: `JSONEncoder` the `[Tool]` (SDK `Tool` is `Codable`; same bytes as the legacy path), wrap with `resultType`, `ttlMs`, `cacheScope`, `_meta.serverInfo` |
| `tools/call` | SDK `CallTool` handler (`RemoteMCPServer.swift` 36–44) reads `Server.currentHandlerContext?.httpContext` to build `ToolGateway.Caller` from the three `X-NR-*` headers, then `gateway.call(name:arguments:caller:)` | `ModernPath` builds the same `Caller` straight from `request.headers` (SDK `HTTPRequest.header(_:)` is case-insensitive, `HTTPServerTypes.swift` 57–60), decodes `arguments` into `[String: Value]` (SDK `Value` is `Codable`), calls the **same** `gateway.call`; encodes `CallTool.Result` with `JSONEncoder`, adds `resultType` and `_meta`. Audit line (`ToolGateway.call` 69–84: `tool.call`/`tool.error`, `clientID`, `tokenFamily`, `ip`) is therefore identical for both eras |
| Header validation (`Mcp-Method`, `Mcp-Name`, version match, sentinel decode) | none (SDK has no such validators in 0.12.1) | new in `ModernPath` (or a `ModernHeaderValidator` struct for unit testing); must run **after** the era classifier so legacy requests are never subjected to it |
| `-32022` / `-32020` / `-32602` / `-32601` bodies | SDK `HTTPResponse.error` cannot carry `data` (PR 314 had to rewrite it) | `ModernPath` serialises its own error envelopes with `JSONSerialization` (`id` echoed, `.withoutEscapingSlashes` as in `initializeReply`) |
| Kill switch / DISABLED | `ToolGateway.perform` step 1 → `unavailable(for:)` `available:false` result (281–295) | unchanged; `server/discover` and `tools/list` succeed while disabled (they carry no vault data), `tools/call` returns the same `available:false` result in either era |
| Body size, Host, error-body middleware | `App.swift` 28–30 | unchanged |
| CLI wiring | `Sources/RemoteServerCore/CLI/Commands.swift` 78–79: `RemoteMCPServer(gateway:)` then `RemoteApp.build(...)` | unchanged (the router is internal to `RemoteMCPServer`) |

Version constants: `RemoteMCPServer.initializeReply` uses the SDK's `Version.supported`/`Version.latest` (legacy). The modern set must be ours: `static let modernVersions = ["2026-07-28"]` in `ModernPath`; do not mix the two (the TypeScript SDK's rule "adding a revision here can never leak a modern version string into a 2025-era handshake").

**Tests that need siblings** (`Tests/RemoteServerCoreTests/`): `HTTPTests.swift` harness `withApp` (15–38) + `rpc(_:_:_:)` (40–42) + `bearer()` — add a `modern(id:method:params:)` body builder that injects `_meta` and a `modernHeaders(method:name:)` helper. Siblings: `fullMCPRoundTrip` (231) → `modernRoundTrip`; `concurrentCallersWithTheSameRequestIDDoNotCollide` (294) → modern-only and **mixed-era** concurrent; `initializeSucceedsForEveryClientNotJustTheFirst` (199) keeps passing unchanged (it sends `2026-07-28` *inside a legacy initialize*, which must stay legacy); `htmlAcceptIs406` (344) → modern; `getAndDeleteOnMcpAre405` (116) → with 2026 headers; `clientSuppliedInternalHeadersAreIgnored` (357) and `auditNeverContainsSpoofedOrSecretValues` (375) → modern `tools/call`; `registerAndUnknownPathsAre404WithEmptyBodies` (142) unchanged; `ToolGatewayTests.catalogIsTheSevenReadOnlyToolsWithKeywordSearch` (286) → assert the modern `tools` array equals the legacy one byte-for-byte. `OAuth*Tests` need nothing. Scripts: `scripts/remote-vault/stage1-tools.sh` (196–218) drives the legacy sequence; add a modern block (`server/discover` → `tools/list` → `vault_overview`) asserting `resultType`, exactly 7 tools, `readOnlyHint`; `stage1-check.sh` adds "`POST /mcp` `server/discover` without a token → 401" (unauthenticated surface unchanged by era).

---

## (f) Design options

### A — modern-path router in front of the SDK (recommended)

A new `MCP/ModernPath.swift` (plus header-validation helpers) invoked from `RemoteMCPServer.handle` for requests the classifier marks modern. Implements exactly: `server/discover`, `tools/list`, `tools/call` (via `ToolGateway`), rows V1–V6, U1/U2, T3; everything else stays on the SDK. No new route, no new tool, no SDK fork, no state.

Risks and mitigations:
- *Hand-rolled wire format drifts from the spec.* Mitigation: the build spec pins the exact JSON of (b) as table tests; a single `modernVersions` constant; `swiftformat`/CI unchanged.
- *Classifier edge: a legacy client that happens to send a 2026 header on a non-initialize request* (SDK clients don't; Python legacy mode sends the negotiated version). It would land on the modern path and fail V6 with a recognised 400, i.e. no silent misbehaviour.
- *`Mcp-Name` sentinel decoding bugs.* Mitigation: table test with the five spec examples ([#value-encoding](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#value-encoding)).
- *`subscriptions/listen` and `ping` shapes are a judgement* until the live capture (section h) says what Claude's clients send.
- *Duplicated `Tool` encoding path.* Mitigation: encode the same `[Tool]` with the same `JSONEncoder` settings; test equality against the legacy response.
- *Later SDK support means a second implementation exists.* Acceptable: when swift-sdk ships 2026 support, deleting `ModernPath` is a one-commit change gated by the same tests.
- Size: ~300 lines code, ~250 lines tests, one Sonnet builder, one critique round. Linux build via CI `linux-packages` (no new dependencies).

### B — wait for swift-sdk

Cheapest if it lands; unbounded otherwise. Evidence against waiting: PR 314 has had no maintainer engagement in six days while unrelated PRs merged; its three prerequisites have waited five weeks; the maintainers' own 2026 tracker issues are untouched since June; and even PR 314 as written lacks `Mcp-Method`/`Mcp-Name` validation and mis-answers `listen` on the stateless transport, so a merge would still leave us non-conformant. Meanwhile every connection by a 2026 client costs one extra 400 round-trip and depends on a fallback no one has promised to keep.

### C — replace the SDK transport entirely

Re-implement the legacy `initialize`/`notifications/initialized`/`ping`/`tools/*` handling ourselves and drop `StatelessHTTPServerTransport` + `Server`. Gains: removes the transport with the known id-collision bug (#265) and the `nr-N` rewrite. Costs: a second era to re-implement and re-test, ~2× option A, and MCPKit (the local stdio server) keeps the SDK dependency anyway. Not now; A is structured so that C can follow if the legacy path ever becomes a liability.

**Honest recommendation:** A. Not urgent today — nothing is broken — but bounded, testable, and it closes the only known unpromised dependency in the remote path.

---

## (g) Draft acceptance criteria and test table (for `specs/mcp-2026/01-modern-path.md`)

Acceptance criteria:
1. A conformant 2026-07-28 client completes `server/discover` → `tools/list` → `tools/call` with HTTP 200 on every step and never sends `initialize`.
2. Every modern result carries `resultType: "complete"` and `_meta["io.modelcontextprotocol/serverInfo"]`; `server/discover` and `tools/list` carry `ttlMs >= 0` and `cacheScope ∈ {"public","private"}`.
3. `tools/list` (modern) advertises exactly the seven read-only tools in the same order and with the same JSON as the legacy path; no `x-mcp-header` keys anywhere in `inputSchema`.
4. `tools/call` (modern) goes through `ToolGateway.call` with the HTTP layer's `Caller`, so clamps, caps, framing, replica fields and the audit line are identical to legacy.
5. Version mismatch, header mismatch, missing required `_meta`, unknown method, and unknown version return the exact status/code pairs of rows V1–V6, U1–U2, each with the caller's `id` echoed.
6. Legacy clients are unaffected: every existing `HTTPTests` case passes unchanged; `initialize` with any header is answered by `initializeReply`.
7. Modern and legacy clients can be served concurrently on one process with colliding JSON-RPC ids.
8. Unauthenticated, Host-mismatched, oversized and rate-limited requests are rejected before era classification (same status codes as today, no body parsing).
9. Kill switch: `server/discover` and `tools/list` still answer while DISABLED; `tools/call` returns `available: false` in both eras.
10. No new public route, no new tool, no new outbound connection; `stage1-check.sh` expectations unchanged except the added 401 probe; design doc §4.2 gets a dated note.
11. `scripts/verify.sh 3 --install` passes; CI `linux-packages` green.

Test table:

| Test | Input | Expect |
|---|---|---|
| `discoverAnswersStatelessly` | D1 ×3 from "different clients" | 200 each; `supportedVersions == ["2026-07-28"]`; `capabilities.tools.listChanged == false`; `instructions` contains "read-only replica"; `ttlMs`, `cacheScope` present; id echoed (string and number ids) |
| `modernToolsListIsTheSevenToolsInStableOrder` | L1 twice | 200; 7 names in MCPKit order both times; `tools` JSON equals the legacy `tools/list` `tools` JSON; `search.inputSchema.properties.mode` absent; every `annotations.readOnlyHint == true` |
| `modernToolsCallGoesThroughTheGateway` | C1 `read_note Inbox.md` | 200; `resultType == "complete"`; `structuredContent.path == "Inbox.md"`; text starts with the untrusted frame; `replica_generated_at` present; audit has one `tool.call` with `client_id`/`token_family` from the stamped headers |
| `modernErrorResultsStayInBand` | C1 with unknown tool / oversized path arg | 200, `isError == true`; audit `tool.error` |
| `unsupportedVersionIs32022` | V1 with `"2026-12-01"` header and body | 400; `error.code == -32022`; `data.supported == ["2026-07-28"]`; `data.requested == "2026-12-01"` |
| `headerBodyVersionMismatchIs32020` | V2 | 400; `-32020`; id echoed |
| `missingOrWrongMcpMethodIs32020` | V3 (absent; `Mcp-Method: tools/list` on a `tools/call`) | 400; `-32020` |
| `mcpNameIsValidatedWithSentinelDecoding` | V4 variants: absent; wrong; `=?base64?cmVhZF9ub3Rl?=` (= `read_note`, must pass); invalid chars | 400/400/200/400 |
| `modernBodyWithoutVersionHeaderIs32020` | V5 | 400; `-32020` |
| `missingRequiredMetaIs32602` | V6 (header 2026, `_meta` lacks `clientCapabilities`) | 400; `-32602` |
| `unknownModernMethodIs404` | U1 for `resources/list`, `prompts/list`, `ping`, `logging/setLevel`; U2 `subscriptions/listen` | 404; `-32601`; id echoed |
| `initializeIsAlwaysLegacy` | `initialize` with `MCP-Protocol-Version: 2026-07-28` and `_meta` modern | 200; `protocolVersion == "2025-11-25"` (existing test extended) |
| `legacyRequestsNeverSeeModernValidation` | legacy `tools/list` with no `Mcp-Method` | 200 (unchanged) |
| `mixedEraConcurrentCallersDoNotCollide` | 4 modern + 4 legacy `tools/call` all `id: 7` | each gets its own path back |
| `sessionAndLastEventIdHeadersAreIgnored` | D1 with `Mcp-Session-Id: x`, `Last-Event-ID: 1` | 200; no `Mcp-Session-Id` in the response |
| `modernNotificationIs202` | T3 | 202, empty body |
| `authRunsBeforeEraClassification` | D1 without bearer | 401 with the existing challenge; nothing in the body is parsed (audit `auth.missing` only) |
| `disabledReplicaStillDiscovers` | DISABLED marker; D1, L1, C1 | 200/200/200 with `available:false` on C1 |
| `noToolSchemaDeclaresXMcpHeader` | catalog | no `x-mcp-header` key at any depth |
| `modernGetAndDeleteAre405` | T1 with 2026 headers | 405, `Allow: POST` |
| Script | `stage1-tools.sh` modern block; `stage1-check.sh` 401 probe | PASS lines |

---

## (h) Open questions only a live capture can answer

Capture on CT 120 with the header-only loopback method from PROGRESS 221 (`tcpdump -i lo` port 8787, filtered to request line, `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, `Mcp-Session-Id`, `Last-Event-ID`, `Accept`, `Content-Type`, response status, and from the JSON body **only** the `method`, the `id` *type* (string/number), the `_meta` key names and the `protocolVersion` value — never `Authorization`, never arguments, never results, never `clientInfo` strings beyond presence).

| # | Question | Fields to capture |
|---|---|---|
| H1 | Exact opening sequence of Duet, Claude Desktop and claude.ai (web): is it `server/discover` first, or an inline `tools/list` with `_meta`? Do they re-probe on every session or cache the era? | per request: method, header version, status; per session: order |
| H2 | Which of the three clients send 2026 at all today? (PROGRESS 221 confirms Duet; claude.ai web unconfirmed) | client (by connector), header version |
| H3 | After a successful `server/discover`, does any client send `subscriptions/listen`? If answered `404 -32601`, does it continue (`tools/list` follows) or abort/fall back? | method sequence, status, next request |
| H4 | Do they send `ping` in modern mode (removed in 2026)? | method, status |
| H5 | Do they send `Mcp-Method` and `Mcp-Name` (and in what case), and is `Mcp-Name` ever sentinel-encoded? | header names present, encoded-or-not |
| H6 | Do they send `Mcp-Session-Id` or `Last-Event-ID` on modern requests? | header presence |
| H7 | Exact `Accept` value (`application/json, text/event-stream`?) | `Accept` |
| H8 | After a `-32022` (test by temporarily advertising only a fake version in a staging build — not on production), do they retry with a version from `supported`? | version on retry, status |
| H9 | Are `id`s strings or numbers, and do concurrent clients reuse small integers (relevant only to the legacy path's `nr-N` rewrite)? | id type |
| H10 | After deploy: audit shows `tool.call ok` with `client_id`/`token_family` for modern calls from both clients, and the fallback `initialize` no longer appears | audit event names only |

---

## What I could not verify

- Which Claude surfaces send 2026 today beyond Duet (H2); no Anthropic page lists it.
- Any sunset for the `initialize` fallback — none exists in Anthropic docs or the spec.
- Whether `subscriptions/listen` is expected by Claude's clients and how a 404 is handled (H3).
- Whether the connector dialog's pasted client ID path is formally documented for 2026 — it works in practice (PROGRESS 221) and matches spec priority 1, but the claude.com page describes developer-portal listings rather than custom connectors.
- The `cacheScope` choice: both `"public"` (spec: "appropriate for lists of tools … identical for all users") and `"private"` are compliant; `"private"` recommended as the fail-closed default **[judgement]**.

---

## Summary

A minimal 2026-07-28 tools-only server needs three methods (`server/discover`, `tools/list`, `tools/call`), per-request `_meta` validation, three header checks (`MCP-Protocol-Version` = body version, `Mcp-Method`, `Mcp-Name` with base64 sentinel), `resultType`/`serverInfo` on results, `ttlMs`/`cacheScope` on discover and list, and the exact error pairs `400 -32022`, `400 -32020`, `400 -32602`, `404 -32601`, plus `405` on GET/DELETE and ignoring `Mcp-Session-Id`. `subscriptions/listen` has no MUST for a server without `listChanged`; answer `404 -32601` pending a live capture. OAuth needs nothing: `iss` is already emitted and advertised, pre-registration is the spec's first-priority mechanism and what claude.ai uses, DCR/`application_type` do not apply, and no new route is required. swift-sdk has no 2026 release and its only PR (#314) is unreviewed and incomplete; TypeScript and Python SDKs already serve both eras on one endpoint. Recommend option A (a ~300-line modern-path router inside `RemoteMCPServer.handle` reusing `ToolGateway`, `RemoteToolCatalog`, `InternalHeaders`), built after a live capture settles the `listen`/`ping` shapes; not urgent, but it removes a dependence on an unpromised client fallback.
