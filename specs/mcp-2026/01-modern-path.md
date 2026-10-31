# 01 — MCP 2026-07-28 modern path in `notetaker-remote` (dual-era `/mcp`)

Status: SPEC, 2026-10-31. Source: `specs/mcp-2026/00-research.md` (option A, recommended there; its sections (b), (e) and (g) are the inputs to this file) and Part 2 of `~/.claude/plans/idempotent-conjuring-bear.md`. This file is the build contract for **one Sonnet builder**; where it and the research differ, this file wins (§0 lists the differences). Facts marked **[verified]** were read from code or the spec pages on 2026-10-31; **[capture]** marks a shape the orchestrator confirms with the live header-only capture (§6.2) before merge.

Design in one paragraph: `RemoteMCPServer.handle` gets a classifier in front of the swift-sdk 0.12.1 transport. A POST whose body carries 2026-era per-request `_meta`, or whose `MCP-Protocol-Version` header names a 2026 version, or whose method exists only in the 2026 era, is answered by our own code (`ModernPath`): `server/discover`, `tools/list`, `tools/call` through the existing `ToolGateway`, plus the exact 2026 error shapes (`-32022`, `-32020`, `-32602`, `404 -32601`). Everything else — `initialize` with any header, legacy `tools/*`, `ping`, notifications without 2026 markers — takes the SDK path exactly as today. No new public route, no new tool, no SDK change, no state: the server becomes a "dual-era server" per the versioning page's compatibility matrix.

## 0. What changed against the research (decision record)

| Research said | This spec | Why |
|---|---|---|
| T3: a modern notification gets `202` "via today's SDK behaviour" | The router answers modern notifications itself with `202` and discards them | **[verified]** `RemoteMCPServer.handle` only intercepts bodies with an `id`; a notification falls through to `StatelessHTTPServerTransport.handlePost`, which runs `ProtocolVersionValidator` *before* the notification branch, so a `MCP-Protocol-Version: 2026-07-28` notification is a `400 -32600` today, not a `202`. The transport page says "header requirements for notification POSTs are not defined by this revision" and the server "MUST return 202 Accepted with no body" if it accepts one |
| Classifier: `_meta` version "present and `>= 2026-07-28`" | Presence of the key `io.modelcontextprotocol/protocolVersion` in `params._meta` (any value) marks the request modern | The key did not exist before 2026-07-28, so no legacy client sends it; and research row V1 wants `"1900-01-01"` in `_meta` to get `-32022`, which the `>=` rule could not deliver (it would fall to the SDK's `-32600`) |
| L1/AC 3: modern `tools` JSON equals the legacy one "byte-for-byte" | Equal **as JSON values** (decoded `[[String: Any]]`, compared as `NSArray`) | **[verified]** the legacy reply is re-serialised by `handle` with `JSONSerialization` (no `.sortedKeys`) when it restores the caller's id, so legacy bytes are not canonical; value equality is the property that matters (same seven tools, same fields, same order) |
| `-32602` for an unknown `cursor` (status unstated) | Every error the router emits has a non-200 status: `-32602` and `-32020` and `-32022` → `400`, `-32601` → `404`, `-32600` → `400`, `-32603` → `500`. Gateway `isError` results stay `200` | One rule, no per-case judgement; the only MUSTs in the spec (`_meta` → `400`, header validation → `400`, unknown method → `404`) are consistent with it |
| `ping` listed in U1 only | `ping` on the **modern** path → `404 -32601`; `ping` on the **legacy** path unchanged (SDK answers `{}`) | The era decides; `sixtyFirstToolCallInAMinuteIs429` sends legacy `ping` and must keep passing |

## 1. Scope

In scope: one new Swift file plus a small hook in `RemoteMCPServer.swift`; tests; modern blocks in `scripts/remote-vault/stage1-check.sh` and `stage1-tools.sh`; a dated note in `specs/remote-vault/00-security-design.md`; a RUNBOOK drill entry. Out of scope: §13.

Project gate (CLAUDE.md "Remote vault"): a new route or tool is a security change. This work adds **neither** — it changes how `POST /mcp` interprets a body — so the design doc gets a dated note (§7.6) and `stage1-check.sh` gets probes that assert the unauthenticated and 405 surfaces are the same in both eras (§7.4). The authenticated tool surface stays exactly the seven read-only tools of `RemoteToolCatalog.tools()`.

## 2. Fixed names and constants (the builder uses these verbatim)

| Item | Value |
|---|---|
| New file | `Packages/RemoteServer/Sources/RemoteServerCore/MCP/ModernPath.swift` (one file; if it passes ~400 lines the pure header helpers may move to `MCP/ModernHeaders.swift`, nothing else) |
| Type | `struct ModernPath: Sendable { let gateway: ToolGateway }` owned by `RemoteMCPServer`; no actor state, no mutable statics |
| Modern versions | `static let supportedVersions = ["2026-07-28"]` and `static let modernFloor = "2026-07-28"` in `ModernPath`. Never merge with the SDK's `Version.supported`/`Version.latest` (those stay the legacy set used by `initializeReply`) |
| `_meta` keys | `io.modelcontextprotocol/protocolVersion`, `io.modelcontextprotocol/clientCapabilities` (required); `io.modelcontextprotocol/clientInfo`, `io.modelcontextprotocol/logLevel` (optional, ignored); result key `io.modelcontextprotocol/serverInfo` |
| Headers | `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` (read case-insensitively via `HTTPRequest.header(_:)` **[verified]**); `Mcp-Session-Id`, `Last-Event-ID`, `Mcp-Param-*` ignored |
| Sentinel | prefix `=?base64?`, suffix `?=`, lowercase, case-sensitive; payload = standard Base64 of the UTF-8 value |
| `serverInfo` | `{"name": NotetakerMCPServer.serverName, "version": NotetakerMCPServer.version}` (`"notetaker"`, **[verified]**) |
| `capabilities` | `{"tools":{"listChanged":false}}` — the same literal `initializeReply` uses **[verified]** |
| `instructions` | `RemoteToolCatalog.instructions` |
| Cache hints | `ttlMs: 3600000`, `cacheScope: "private"` on `server/discover` and `tools/list` |
| Result stamp | every success result gets `"resultType":"complete"` and `"_meta":{"io.modelcontextprotocol/serverInfo":{…}}` |
| Response headers | success and error bodies: `Content-Type: application/json`; `202` has no body and no `Content-Type`; never `Mcp-Session-Id` |
| Serialisation | `JSONSerialization` with `[.withoutEscapingSlashes]` for envelopes (as `initializeReply`); `JSONEncoder` with `[.sortedKeys, .withoutEscapingSlashes]` for `[Tool]` and `CallTool.Result` (the SDK's own settings **[verified: Server.swift 372]**), then spliced into the envelope as a decoded `[String: Any]` |

## 3. Request classification (runs inside `RemoteMCPServer.handle`, after the HTTP layer)

Precondition (unchanged): `MCPEndpoint.handle` has already authenticated (401 + tarpit), applied the optional Anthropic IP allowlist (403), charged the global tool bucket (429), stripped client `x-nr-*` headers, dropped `Authorization`, and stamped `X-NR-Client-Id` / `X-NR-Token-Family` / `X-NR-Client-Ip` **[verified: App.swift 170–221]**. Body size (413) and Host (421) ran before that. The classifier never sees an unauthenticated request.

Let `message` be the body parsed by `JSONSerialization` as `[String: Any]`. If the body is absent, not an object, or has no `method` string → **not classified**; today's code path (SDK) handles it (parse error `-32700`/`-32600` as now). Otherwise, in this order:

1. `method == "initialize"` → **legacy, always**, whatever the header or `_meta` say → existing `initializeReply` (requires the existing String/NSNumber `id`; without one it goes to the SDK as today).
2. **Modern** if any of:
   - `method` is `server/discover` or `subscriptions/listen` (methods that exist only in 2026);
   - `params` is an object whose `_meta` is an object containing the key `io.modelcontextprotocol/protocolVersion` (any value, any type);
   - the `MCP-Protocol-Version` header is present and compares lexically `>= modernFloor` (ISO dates compare correctly as strings; `"2026-07-28" >= "2026-07-28"` is true, `"2025-11-25"` is not, `"3000-01-01"` is).
3. Otherwise **legacy** → the existing id-rewrite + `transport.handleRequest` path, untouched.

Consequences the builder must preserve and test:

- A modern header with a legacy body (header `2026-07-28`, no `_meta` version) is modern and fails §4 step 2 with `400 -32602` (V6). It does not reach the SDK.
- A legacy header with a modern body (`_meta` version present, header `2025-11-25` or absent) is modern and fails §4 step 3 with `400 -32020` (V2/V5).
- A legacy header with a legacy body, including a bogus header like `1900-01-01` and no `_meta`, is legacy: the SDK's `ProtocolVersionValidator` answers `400 -32600` exactly as today. Not our concern.
- A modern **notification** (no `id` key, classified modern by header or `_meta`) → `202`, empty body, nothing yielded to the SDK, no validation, no audit line. A legacy notification keeps today's SDK path (`202`).
- A JSON-RPC **response** body (`result`/`error`, no `method`) is not classified and keeps today's path.
- A modern request whose `id` is present but neither a String nor an NSNumber (JSON `null`, object, array) → `400` `-32600` `"Invalid Request: id must be a string or number"` with `"id": null`. (JSON-RPC in MCP: "the ID MUST NOT be null" **[verified: basic/index]**.)

## 4. Modern request validation (fixed order; the first failure answers)

Every error below is `{"jsonrpc":"2.0","id":<caller's id, echoed verbatim>,"error":{"code":…,"message":…}}` with `data` only where shown. Status per §0 rule.

| Step | Check | Failure |
|---|---|---|
| 1 | `Accept` and `Content-Type`, using the SDK's own validators so the eras cannot drift: `AcceptHeaderValidator(mode: .jsonOnly).validate(request, context:)` and `ContentTypeValidator().validate(request, context:)` with `HTTPValidationContext(httpMethod: "POST")` **[verified: public init]**. Return the SDK's response unchanged | `406` / `415` (SDK bodies, `id: null`, as today for legacy) |
| 2 | `params._meta` is an object with `io.modelcontextprotocol/protocolVersion` a **string** and `io.modelcontextprotocol/clientCapabilities` an **object** (may be `{}`). Check in that order; name the first missing or mistyped key | `400` `-32602` `"Invalid params: _meta.io.modelcontextprotocol/protocolVersion is required"` or `"…clientCapabilities is required"` (V6) |
| 3 | `MCP-Protocol-Version` header present | `400` `-32020` `"Header mismatch: MCP-Protocol-Version header is missing"` (V5) |
| 4 | header value `==` `_meta` version (exact, case-sensitive, after trimming leading/trailing ASCII space or tab from the header only) | `400` `-32020` `"Header mismatch: MCP-Protocol-Version header value '<header>' does not match body value '<meta>'"` (V2) |
| 5 | version `∈ supportedVersions` | `400` `-32022` `"Unsupported protocol version"` with `"data":{"supported":["2026-07-28"],"requested":"<meta>"}` (V1) |
| 6 | `Mcp-Method` header present and `==` body `method` (trim as in 4) | `400` `-32020` `"Header mismatch: Mcp-Method header is missing"` / `"Header mismatch: Mcp-Method header value '<header>' does not match body value '<method>'"` (V3) |
| 7 | `method ∈ {server/discover, tools/list, tools/call}` | `404` `-32601` `"Method not found"` (U1, U2) |
| 8 | `tools/call` only: `params.name` is a string | `400` `-32602` `"Invalid params: name is required"` |
| 9 | `tools/call` only: `Mcp-Name` present; decode (§4.1); decoded value `==` `params.name` | `400` `-32020` `"Header mismatch: Mcp-Name header is missing"` / `"Header mismatch: Mcp-Name header value contains invalid characters"` / `"Header mismatch: Mcp-Name header does not match params.name"` (V4). The name is deliberately **not** echoed (it is client-chosen and may be long or binary) |
| 10 | `tools/call` only: `params.arguments`, when present, is an object | `400` `-32602` `"Invalid params: arguments must be an object"` |
| 11 | `tools/list` only: `params.cursor`, when present | `400` `-32602` `"Invalid params: unknown cursor"` (this server never mints one) |

Header values that reach the comparison through `MCPEndpoint.flatten` with two field lines are joined with `", "` **[verified]** and therefore mismatch → `-32020`; acceptable, document in a code comment. Values are compared as Swift `String ==` (Unicode canonical equivalence); the tool names and method names are ASCII so this is exact.

### 4.1 `Mcp-Name` decoding (pure function, unit-tested)

`static func decodeName(_ raw: String) -> String?` (nil = "invalid characters"):

1. Trim leading/trailing ASCII space and tab (HTTP OWS; python-sdk #3763 shows clients pad).
2. If the value has the prefix `=?base64?` **and** the suffix `?=` (both lowercase, literal): take the middle, Base64-decode with the standard alphabet (padding required as sent by `Data.base64EncodedString()`; reject if `Data(base64Encoded:)` returns nil), decode as UTF-8 (reject if invalid), return it. The decoded value may contain anything, including another sentinel — it is **not** decoded again.
3. Otherwise every scalar must be in `0x21...0x7E` or `0x20`; anything else (control characters, non-ASCII, tab inside the value) → nil. Return the value.

Table test (the spec's own examples, transposed to `Mcp-Name` **[verified: transports page, "Encoding examples"]**): `read_note` → `read_note`; `=?base64?cmVhZF9ub3Rl?=` → `read_note`; `=?base64?SGVsbG8sIOS4lueVjA==?=` → `Hello, 世界`; `=?base64?IHBhZGRlZCA=?=` → ` padded `; `=?base64?bGluZTEKbGluZTI=?=` → `line1\nline2`; `=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=` → `=?base64?literal?=`; `=?base64?***?=` → nil; `=?BASE64?cmVhZF9ub3Rl?=` → treated as plain (uppercase marker is not the sentinel) and then nil is **not** returned because every character is printable ASCII: it compares unequal to `read_note` → `-32020` at step 9; `caf\u{E9}` → nil; `"  read_note "` → `read_note`.

## 5. Handlers (verbatim shapes)

Every request below passed §4. `<id>` is the caller's id (string or number, echoed as sent); `<v>` is `NotetakerMCPServer.version`.

### 5.1 `server/discover` (D1)

Request: `{"jsonrpc":"2.0","id":"discover-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"ExampleClient","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}` with headers `MCP-Protocol-Version: 2026-07-28`, `Mcp-Method: server/discover`.

Response `200`:

```json
{"jsonrpc":"2.0","id":"discover-1","result":{
  "resultType":"complete",
  "supportedVersions":["2026-07-28"],
  "capabilities":{"tools":{"listChanged":false}},
  "instructions":"<RemoteToolCatalog.instructions>",
  "ttlMs":3600000,
  "cacheScope":"private",
  "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"notetaker","version":"<v>"}}}}
```

Answers while the replica is DISABLED, empty or inconsistent (it carries no vault data). Any extra `params` keys are ignored.

### 5.2 `tools/list` (L1)

Request `params` = `{"_meta":{…}}`. Response `200`:

```json
{"jsonrpc":"2.0","id":<id>,"result":{
  "resultType":"complete",
  "tools":[ <RemoteToolCatalog.tools() encoded with the §2 JSONEncoder, in array order> ],
  "ttlMs":3600000,
  "cacheScope":"private",
  "_meta":{"io.modelcontextprotocol/serverInfo":{…}}}}
```

No `nextCursor` key (single page). Order is the `NotetakerMCPServer.tools()` literal order (`vault_overview, list_folder, read_note, search, tasks, calendar_agenda, calendar_list` **[verified]**), identical on every call. Answers while DISABLED.

### 5.3 `tools/call` (C1, C2)

Request `params` = `{"name":"read_note","arguments":{"path":"Inbox.md"},"_meta":{…}}` with `Mcp-Method: tools/call`, `Mcp-Name: read_note`.

Implementation: build `ToolGateway.Caller(clientID: request.header(InternalHeaders.clientID), tokenFamily: request.header(InternalHeaders.tokenFamily), ip: request.header(InternalHeaders.clientIP))` — the same three stamped headers the SDK `CallTool` handler reads **[verified: RemoteMCPServer.swift 36–44]**; decode `params.arguments` (default `{}`) into `[String: Value]` by re-serialising the sub-object with `JSONSerialization` and decoding with `JSONDecoder` (SDK `Value` is `Codable`); call `gateway.call(name:arguments:caller:)`; encode the returned `CallTool.Result` with the §2 encoder, decode to `[String: Any]`, add `resultType` and `_meta`, wrap. Response `200`:

```json
{"jsonrpc":"2.0","id":<id>,"result":{
  "resultType":"complete",
  "content":[{"type":"text","text":"<framed, as today>"}],
  "structuredContent":{…, "replica_generated_at":"…", "stale":false, …},
  "isError":false,
  "_meta":{"io.modelcontextprotocol/serverInfo":{…}}}}
```

Gateway error results (unknown tool, clamp failure, timeout, oversize) come back `200` with `"isError":true` and `resultType":"complete"`, exactly as the SDK path returns them — the audit line (`tool.call` / `tool.error`, with `client_id`, `token_family`, `ip`) is written by `ToolGateway.call` and is therefore identical in both eras. While DISABLED the gateway's `available:false` result is returned the same way. Known deviation, recorded here on purpose: the 2026 schema prefers `-32602` for an unknown tool name; we keep the in-band `isError` so the era does not fork gateway behaviour.

### 5.4 Everything else

`resources/list`, `prompts/list`, `ping`, `logging/setLevel`, `resources/subscribe`, `completion/complete`, `tasks/*`, `subscriptions/listen` and any other method on the modern path → `404 -32601` (§4 step 7). `GET`/`DELETE`/`PUT`/`PATCH /mcp` → `405` with `Allow: POST` from the Hummingbird router **[verified: App.swift 36–42]**, before any header is read. `Mcp-Session-Id` and `Last-Event-ID` are never read, minted or echoed.

## 6. `subscriptions/listen` and `ping`: the decision, and what the capture confirms

### 6.1 Decision

- `subscriptions/listen` → `404 -32601` (U2). Justification from the research: no MUST requires a server to implement it; `ServerCapabilities` has no `subscriptions` field; we advertise `tools.listChanged: false` and nothing else, so a listen stream could never carry anything; the caching page lets a client "rely entirely on TTL-based freshness" when `listChanged` is not advertised; and a `404 -32601` is a *recognised* modern error, so a client does not fall back to `initialize` on it. Do **not** copy swift-sdk PR 314's `400 -32600` for `listen` (an unrecognised error that would trigger fallback).
- `ping` on the modern path → `404 -32601` (removed in 2026-07-28, changelog item 5). Legacy `ping` unchanged.

### 6.2 Confirm by live capture before merge (orchestrator; §11.4 has the command)

The builder implements the decisions above as written. The orchestrator runs the capture on CT 120 with the **current** binary (which still answers `400 -32600` to everything modern) while Duet and claude.ai connect, and records only methods, header names, `_meta` key names, version strings and status codes. These rows of research (h) gate the merge:

| Capture question | If the capture shows… | Adjustment (one line each; no re-spec) |
|---|---|---|
| H1 opening sequence: `server/discover` first, or inline `tools/list`? | either | none — both are handled |
| H1/H5: does `server/discover` carry `_meta.clientCapabilities`? | **absent** on `server/discover` only | relax §4 step 2 for `server/discover` alone: treat a missing `clientCapabilities` as `{}`; add the test row; everything else stays strict |
| H3: after `discover`, is `subscriptions/listen` sent, and does the client continue after a `404 -32601`? | the client **aborts or falls back** after the 404 | stop and ask; the candidate change is a `200` SSE stream that sends `notifications/subscriptions/acknowledged` and keeps the connection open, which is a new behaviour (streaming, lifetime) and needs its own spec |
| H4: is `ping` sent in modern mode, and does `404` hurt? | the client treats the 404 as fatal | stop and ask (same reasoning as H3) |
| H5: `Mcp-Method` / `Mcp-Name` present? sentinel-encoded? | absent on a client we must serve | stop and ask: the MUST is on the client; our `-32020` is spec-conformant, but we would be refusing the only clients we care about |
| H6: `Mcp-Session-Id` / `Last-Event-ID` present? | present | none — ignored by design |
| H7: `Accept` value | lacks `application/json` | stop and ask (the SDK validator, kept in §4 step 1, would 406) |
| H9: id types | any | none — both types are echoed |

H8 (retry after `-32022`) and H10 (audit after deploy) are post-deploy checks (§12).

## 7. Build task (one builder)

Style: match `RemoteMCPServer.swift` (doc comments that say *why*, `guard` early returns, `[String: Any]` envelopes, `.withoutEscapingSlashes`); `swiftformat --lint .` clean; no new dependency; Linux-clean Foundation only (no `NSRegularExpression` needed; `Data(base64Encoded:)` and `String(validatingUTF8:)`/`String(data:encoding:)` exist in corelibs).

### 7.1 `Packages/RemoteServer/Sources/RemoteServerCore/MCP/ModernPath.swift` (new)

Contents, in this order:

1. Header comment: the one-paragraph design from the top of this spec, the sentence "Legacy requests never enter this file", and the pointer to this spec.
2. `struct ModernPath: Sendable` with `let gateway: ToolGateway`, the constants of §2, and
   - `static func isModern(method: String, message: [String: Any], request: HTTPRequest) -> Bool` (§3 rule 2 only; rule 1 stays in `RemoteMCPServer.handle`).
   - `func handle(_ request: HTTPRequest, message: [String: Any]) async -> HTTPResponse` (notification → `.accepted()`; otherwise §4 then §5).
   - `static func decodeName(_ raw: String) -> String?` (§4.1).
   - private helpers: `error(id:status:code:message:data:)` producing the §4 envelope. **Note**: `MCP.HTTPResponse` cannot carry a JSON body on a non-200 status (`.data` is always 200; `.error` has no `data` member and `id: null`) **[verified: HTTPServerTypes.swift]**, so the modern path returns its own small value type `ModernReply(status: Int, headers: [String: String], body: Data?)` and `RemoteMCPServer` bridges it as described in §7.2.
   - `discover(id:)`, `listTools(id:)`, `callTool(id:params:caller:) async`, and `stamp(_ result: inout [String: Any])` that adds `resultType` and `_meta`.
3. Nothing in this file reads `Authorization`, writes the audit log, or logs a body. The only I/O is `gateway.call`.

### 7.2 `Packages/RemoteServer/Sources/RemoteServerCore/MCP/RemoteMCPServer.swift` and the status hook

`RemoteMCPServer`:

- Add `private let modern: ModernPath`, initialised in `init` as `ModernPath(gateway: gateway)`.
- `handle` becomes: parse `message` (body as `[String: Any]`, as today, but without requiring `id` yet); if `request.method == "POST"`, `message["method"] as? String` is `"initialize"` and `id` is String/NSNumber → `initializeReply` (unchanged); else if `ModernPath.isModern(...)` → `return await modern.handle(request, message: message)`; else the existing `id` guard, `nr-N` rewrite and SDK call, byte-for-byte as now. Keep the existing doc comments; add two sentences explaining the era split.

Status codes for modern errors: `MCP.HTTPResponse` cannot carry a JSON body on a non-200 status **[verified]**. The hook: keep `handle(_:) async -> HTTPResponse` for the SDK path (tests call it), and add a second public method `respond(_:) async -> ModernReply` that `MCPEndpoint.handle` calls instead of `handle`: it runs §3; for the modern era it returns `modern.handle(...)` directly; for `initialize` and legacy it wraps the `HTTPResponse` from `handle` into a `ModernReply` via `statusCode`/`headers`/`bodyData` (a `.stream` maps to status 500 with no body, as `map` does today). `MCPEndpoint.map` gains an overload `map(_ reply: ModernReply)` (five lines). `App.swift` changes are limited to those two call-site lines; nothing in middleware, routes or auth moves.

### 7.3 Tests

- **`Tests/RemoteServerCoreTests/HTTPTestHarness.swift` (new):** move `withApp`, `rpc`, `bearer`, `jsonBody` from `HTTPTests.swift` into `enum HTTPHarness` with `static` versions of the same signatures (plus `static let metadataURL`, `static let json`). `HTTPTests.swift` keeps private one-line forwarders so its test bodies do not change. Add to the harness: `static func modern(_ id: Any, _ method: String, params: String = "{}", version: String = "2026-07-28", meta: String? = nil) -> ByteBuffer` (injects the standard `_meta` with `clientInfo {"name":"t","version":"1"}` and `clientCapabilities {}` unless `meta` overrides the whole `_meta` object) and `static func modernHeaders(method: String, name: String? = nil, version: String? = "2026-07-28", bearerToken: String = "t") -> HTTPFields` (bearer + JSON + `MCP-Protocol-Version` + `Mcp-Method` + optional `Mcp-Name`; `version: nil` omits the header).
- **`Tests/RemoteServerCoreTests/ModernPathTests.swift` (new):** the §10 rows marked M, using the harness and `ReplicaFixture` (`push(disabled: true)` for the DISABLED rows); plus pure unit tests for `decodeName` (§4.1 table) and `isModern` (§3 cases).
- **`HTTPTests.swift`:** only (a) the forwarders, (b) `initializeSucceedsForEveryClientNotJustTheFirst` extended with a fifth `initialize` that carries `MCP-Protocol-Version: 2026-07-28`, `Mcp-Method: initialize` and a full modern `_meta` → still `200`, `protocolVersion == "2025-11-25"` (row 12). Every other test in the file passes unchanged.
- **`ToolGatewayTests.swift`:** add `noToolSchemaDeclaresXMcpHeader` (row 19) next to `catalogIsTheSevenReadOnlyToolsWithKeywordSearch` **[verified: line 286]**: walk every `Tool.inputSchema` `Value` recursively; no object key equals `x-mcp-header` at any depth.

### 7.4 `scripts/remote-vault/stage1-check.sh`

In the "unauthenticated surface" section, after the existing `POST /mcp without a token -> 401` check and before the `GET DELETE` loop, add: `http POST "$BASE/mcp" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: server/discover' --data-binary '<D1 body>'` → `pass "POST /mcp server/discover (MCP 2026-07-28) without a token -> 401"` else `fail "... - design 10: the era of the request never changes the unauthenticated surface"`; assert the same `resource_metadata=` challenge. In the `GET DELETE` loop add the two 2026 headers to the request (expected `405` unchanged). No other expectation in the script changes; `/register` stays `404`, `/healthz` rules unchanged. The 25-POST flood stays last.

### 7.5 `scripts/remote-vault/stage1-tools.sh`

After the legacy block (`initialize` → `notifications/initialized` → `tools/list`) and before `vault_overview`, add `section "MCP 2026-07-28 modern path (spec mcp-2026/01)"`. Add a helper `mcp_modern <method> <name-or-""> <json-body>` beside `mcp()` that sends the same bearer-from-file header plus `Accept: application/json, text/event-stream`, `MCP-Protocol-Version: 2026-07-28`, `Mcp-Method: <method>` and, when the second argument is non-empty, `Mcp-Name: <name>`; bodies are built with `jq -nc` and always include the standard `_meta`. Checks (one PASS/FAIL line each, FAIL text names "spec mcp-2026/01 §<n>"):

1. `server/discover` → HTTP 200, `.result.resultType == "complete"`, `.result.supportedVersions == ["2026-07-28"]`, `.result.capabilities.tools.listChanged == false`, `.result.ttlMs | type == "number"`, `.result.cacheScope | IN("public","private")`, `.result._meta["io.modelcontextprotocol/serverInfo"].name == "notetaker"`.
2. modern `tools/list` → 200, exactly the 7 names (reuse `$WANT`), `all(.annotations.readOnlyHint == true)`, no `search.inputSchema.properties.mode`, `ttlMs`/`cacheScope` present; and the `.result.tools` array equals the legacy block's `.result.tools` (save the legacy one to `$WORK/tools.legacy.json` and compare with `jq -e --slurpfile`).
3. modern `tools/call vault_overview` (with `Mcp-Name: vault_overview`) → 200, `resultType == "complete"`, `$SC.replica_generated_at` is a string, `check_framing`.
4. `tools/call vault_overview` with `Mcp-Name: list_folder` → 400, `.error.code == -32020`.
5. `tools/list` with no `Mcp-Method` → 400, `-32020`.
6. `server/discover` with version `2026-12-01` in both header and `_meta` → 400, `.error.code == -32022`, `.error.data.supported == ["2026-07-28"]`, `.error.data.requested == "2026-12-01"`.
7. modern `ping` → 404, `-32601`.
8. legacy `tools/list` (no `Mcp-Method`, no 2026 header) still → 200 with 7 tools (the legacy path is untouched by the modern headers sent just before).

These responses go into `$WORK/all-responses` like the others (the transcript scan covers them). The cleanup block is unchanged.

### 7.6 `specs/remote-vault/00-security-design.md` — dated note

Append after §9, same style as §9 (a dated heading, bullets, the facts verified):

```
## 10. Note recorded <build date>: MCP 2026-07-28 served natively on `/mcp`

- `/mcp` is a dual-era endpoint: requests carrying 2026 per-request `_meta` (or a 2026 `MCP-Protocol-Version`, or `server/discover`/`subscriptions/listen`) are answered by `RemoteServerCore/MCP/ModernPath.swift`; `initialize` and legacy requests still go to swift-sdk 0.12.1. Spec: `specs/mcp-2026/01-modern-path.md`; research: `specs/mcp-2026/00-research.md`.
- Nothing in §4.2, §4.4, §4.7 or §4.8 changes: same seven read-only tools (`RemoteToolCatalog`), same `ToolGateway` clamps/caps/framing/audit line, same seven public prefixes, no `/register`, no CIMD, no DCR, no new outbound connection, same body/Host/auth/rate-limit order. `stage1-check.sh` now also proves the unauthenticated surface is era-independent.
- Modern-only behaviour: `server/discover` and `tools/list` answer while the replica is DISABLED (they carry no vault data; `tools/call` returns `available:false` as before); `-32022` lists only `2026-07-28`; `subscriptions/listen` and `ping` are `404 -32601` (no `listChanged`, nothing to stream).
- Recognised 2026 errors (`-32020`, `-32022`, `-32602` on `_meta`, `404 -32601`) are the only non-200 bodies the router emits; none carries a token, a note body or a client-supplied tool name.
```

And in §4.2, append one sentence: "Since <build date> the same endpoint also serves the MCP 2026-07-28 request shape; see §10."

### 7.7 `deploy/remote-vault/RUNBOOK.md` — drill `3.7`

Add after 3.6:

```
### 3.7 MCP 2026-07-28 client drill (after any binary that touches ModernPath)

Header-only capture on the CT, never bodies, never Authorization (spec mcp-2026/01 §11.4 has the exact command). Connect Duet, then claude.ai, then ask each for `vault_overview`.
Expect per client: `POST /mcp` + `MCP-Protocol-Version: 2026-07-28` + `"method":"server/discover"` -> `200`; then `tools/list` -> `200` (or an inline `tools/list` first); `tools/call` with `Mcp-Name: vault_overview` -> `200`; **no** `"method":"initialize"` from that client. A `404` is expected only for `subscriptions/listen` or `ping`, and the client must continue afterwards.
Audit: `grep -c '"event":"tool.call"' /var/log/notetaker-remote/audit.jsonl` grows by at least two, with `client_id`/`token_family` set.
Rollback (any client fails to connect that connected before): `cp -p /usr/local/bin/notetaker-remote.prev /usr/local/bin/notetaker-remote && systemctl restart notetaker-remote` (deploy.sh keeps `.prev`), re-run the capture, record both in PROGRESS.
```

### 7.8 Not in the builder's tree

`PROGRESS.md` (the orchestrator writes the row), `CLAUDE.md`, `FEATURES.md`, `PLAN.md`, `App/**`, `Packages/MCPKit/**`, `Packages/RemoteServer/Package.swift`, `Package.resolved`, `deploy/remote-vault/{ct,host,build,site}/**`, `.github/**`.

## 8. Invariants checklist (the critic ticks each against the diff)

1. Auth (401 + tarpit), Anthropic allowlist (403), tool bucket (429), body limit (413), Host (421) run **before** classification, in today's order; `App.swift` changes are limited to the two call-site lines of §7.2.
2. No new route: `grep -c 'router\.\(get\|post\|on\)' App.swift` unchanged; `stage1-check.sh` 404 expectations unchanged.
3. No new tool, no changed tool: modern `tools` equals legacy `tools` as JSON values; `RemoteToolCatalog` and MCPKit untouched; no `x-mcp-header` anywhere.
4. `tools/call` in both eras goes through the one `ToolGateway.call` with a `Caller` built from the three stamped headers; audit lines are identical in shape and attribution; the router itself writes **no** audit event.
5. Request ids: the modern path never touches `nextRequestNumber` or the SDK waiters; mixed-era concurrency with colliding ids is tested (row 14).
6. Kill switch: DISABLED → `discover`/`list` `200`, `call` `available:false`; `nr-kill`/Mac toggle paths untouched.
7. No body, token, argument, result, `clientInfo` string or `Mcp-Name` value is logged or placed in an error message; error messages contain only our fixed strings, the version strings and the method name.
8. Legacy path byte-identical: every pre-existing `HTTPTests`/`OAuth*Tests`/`ToolGatewayTests` passes unchanged (apart from the one extended `initialize` test).
9. `-32020…-32099`: only `-32020` and `-32022` are emitted; never `-32021` (we require no client capability), never `-32002`.
10. The SDK's `Accept`/`Content-Type` validators are the ones used on both paths (no second implementation).
11. Modern versions live in `ModernPath.supportedVersions` only; `initializeReply` still uses `Version.supported`/`Version.latest`; no 2026 string can appear in an `initialize` result.

## 9. Acceptance criteria

1. A conformant 2026-07-28 client completes `server/discover` → `tools/list` → `tools/call` with HTTP 200 on every step and never needs `initialize`.
2. Every modern success result carries `resultType: "complete"` and `_meta["io.modelcontextprotocol/serverInfo"]`; `server/discover` and `tools/list` carry `ttlMs == 3600000` and `cacheScope == "private"`.
3. Modern `tools/list` advertises exactly the seven read-only tools, in the MCPKit order, equal as JSON values to the legacy list; no `x-mcp-header` key anywhere in any `inputSchema`.
4. Modern `tools/call` runs through `ToolGateway.call` with the HTTP layer's `Caller`: clamps, caps, framing, replica fields, `isError` results and the audit line are identical to legacy.
5. Rows V1–V6, U1–U2 of §4/§5 return exactly the status/code/message pairs of §4, each with the caller's id echoed (string and number).
6. Legacy clients are unaffected: every existing `HTTPTests` case passes unchanged; `initialize` with any header and any `_meta` is answered by `initializeReply`; legacy `ping` still answers.
7. Modern and legacy clients are served concurrently on one process with colliding JSON-RPC ids.
8. Unauthenticated, Host-mismatched, oversized and rate-limited requests are rejected before classification with today's status codes and audit events.
9. Kill switch: `server/discover` and `tools/list` answer while DISABLED; `tools/call` returns `available: false` in both eras.
10. Modern notifications → `202` empty; `Mcp-Session-Id`/`Last-Event-ID` ignored and never echoed; `GET`/`DELETE` with 2026 headers → `405 Allow: POST`.
11. No new public route, no new tool, no new outbound connection; `stage1-check.sh` passes with the two added probes; `stage1-tools.sh` modern block passes; design doc §10 and RUNBOOK 3.7 present.
12. `swift test` for RemoteServer green on macOS; `scripts/verify.sh 3 --install` passes; `swiftformat --lint .` clean; CI `linux-packages` green.

## 10. Test table (M = `ModernPathTests.swift`, H = `HTTPTests.swift`, G = `ToolGatewayTests.swift`, S = scripts)

| # | Test | Input | Expect |
|---|---|---|---|
| 1 | M `discoverAnswersStatelessly` | D1 three times, ids `"discover-1"`, `7`, `"x"` | `200` ×3; body exactly §5.1 modulo `<v>`/instructions; `id` echoed with its type; `instructions` contains "read-only replica"; no `Mcp-Session-Id` response header |
| 2 | M `modernToolsListIsTheSevenToolsInStableOrder` | L1 twice, then legacy `initialize` + `tools/list` | `200`; names in order `vault_overview,list_folder,read_note,search,tasks,calendar_agenda,calendar_list` both times; `tools` as `NSArray` equals the legacy `tools`; `search.inputSchema.properties.mode` absent; every `annotations.readOnlyHint == true`; `ttlMs == 3600000`, `cacheScope == "private"`, `resultType == "complete"`, no `nextCursor` key |
| 3 | M `modernToolsCallGoesThroughTheGateway` | C1 `read_note` `Inbox.md`, `Mcp-Name: read_note` | `200`; `resultType == "complete"`; `isError == false`; `structuredContent.path == "Inbox.md"`, `.content` contains "accreditation", `replica_generated_at` present; `content[0].text` starts with `ToolGateway.preamble` and contains `<untrusted_vault_data>`; audit file has exactly one `tool.call` with `"client_id":"test-client"` |
| 4 | M `modernErrorResultsStayInBand` | C1 with `name: "nope"` (+ `Mcp-Name: nope`); C1 `read_note` with a 2000-char `path` | `200` each; `isError == true`; `resultType == "complete"`; audit has `tool.error` lines with `"tool":"(unknown)"` for the first |
| 5 | M `unsupportedVersionIs32022` | header and `_meta` both `2026-12-01`; then both `1900-01-01` | `400`; `error.code == -32022`; `message == "Unsupported protocol version"`; `data.supported == ["2026-07-28"]`; `data.requested` equals the sent value; id echoed |
| 6 | M `headerBodyVersionMismatchIs32020` | header `2026-07-28`, `_meta` `2025-11-25` | `400`; `-32020`; message == §4 step 4 string with both values; id echoed |
| 7 | M `missingOrWrongMcpMethodIs32020` | L1 without `Mcp-Method`; C1 with `Mcp-Method: tools/list` | `400` `-32020` "…is missing"; `400` `-32020` "…value 'tools/list' does not match body value 'tools/call'" |
| 8 | M `mcpNameIsValidatedWithSentinelDecoding` | C1 `read_note` with `Mcp-Name` absent / `list_folder` / `=?base64?cmVhZF9ub3Rl?=` / `=?base64?***?=` / `caf\u{E9}` (sent as UTF-8 bytes; if HummingbirdTesting cannot send it, cover via the unit test only and say so) / `"  read_note "` | `400`/`400`/`200`/`400`/`400`/`200`; the `400`s are `-32020` with the §4 step 9 messages; no `400` body contains the string `read_note` or `list_folder` |
| 9 | M `decodeNameTable` (unit) | §4.1 table | as listed |
| 10 | M `modernBodyWithoutVersionHeaderIs32020` | L1 body with full `_meta`, header absent; the same with header `2025-11-25` | `400` `-32020` "…header is missing"; `400` `-32020` mismatch |
| 11 | M `missingRequiredMetaIs32602` | header `2026-07-28`, `_meta` without `clientCapabilities`; `_meta` without `protocolVersion`; `_meta` with `protocolVersion: 2026` (number); no `_meta` at all | `400` `-32602` each; messages name `…clientCapabilities` / `…protocolVersion` / `…protocolVersion` / `…protocolVersion` |
| 12 | H `initializeSucceedsForEveryClientNotJustTheFirst` (extended) | fifth `initialize` with 2026 header, `Mcp-Method: initialize`, full modern `_meta` | `200`; `protocolVersion == "2025-11-25"`; `serverInfo.name == "notetaker"`; no `resultType` key (legacy shape) |
| 13 | M `unknownModernMethodIs404` | `resources/list`, `prompts/list`, `ping`, `logging/setLevel`, `subscriptions/listen`, `tasks/list`, each with matching `Mcp-Method` and full `_meta` | `404`; `-32601`; `message == "Method not found"`; id echoed; `Content-Type: application/json` |
| 14 | M `mixedEraConcurrentCallersDoNotCollide` | legacy `initialize`, then a task group of 4 modern + 4 legacy `tools/call read_note` all `id: 7` over the four fixture paths | each response `200`, `id == 7`, `structuredContent.path` equals its own request path; sorted paths equal the fixture's four, twice |
| 15 | M `legacyRequestsNeverSeeModernValidation` | legacy `tools/list` with no `Mcp-Method`; legacy `ping` | `200` with 7 tools; `200` with `result == {}` |
| 16 | M `sessionAndLastEventIdHeadersAreIgnored` | D1 plus `Mcp-Session-Id: x`, `Last-Event-ID: 1` | `200`; response has no `Mcp-Session-Id` header |
| 17 | M `modernNotificationIs202` | body `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"_meta":{<full>}}}` with 2026 header; the same with header only and no `_meta`; the same with no `Mcp-Method` | `202`, empty body, no `Content-Type`, each |
| 18 | M `authRunsBeforeEraClassification` | D1 with 2026 headers and no bearer (DenyAll); D1 with a bogus bearer; D1 with `Host: evil.example`; D1 body padded to 65 KB | `401` with the exact challenge and `auth.missing` in the audit; `401`; `421`; `413`; the audit holds no `tool.*` line |
| 19 | G `noToolSchemaDeclaresXMcpHeader` | `RemoteToolCatalog.tools()` | no object key `x-mcp-header` at any depth |
| 20 | M `disabledReplicaStillDiscovers` | `fixture.push(disabled: true)`; D1, L1, C1 `vault_overview` | `200`/`200`/`200`; C1 `structuredContent.available == false`, `reason` contains "disabled", `isError == false`, `resultType == "complete"` |
| 21 | M `modernGetAndDeleteAre405` | `GET`, `DELETE /mcp` with 2026 headers (no bearer needed) | `405`, `Allow: POST`, empty body |
| 22 | M `modernErrorsAreNon200AndResultsAre200` | every error row above | status ≠ 200 and `error` present ⇔ router error; every `result` is `200`; `Content-Type: application/json` on all bodies |
| 23 | M `isModernTable` (unit) | §3 cases: initialize+2026 header (legacy); `subscriptions/listen` bare (modern); `_meta` version `1900-01-01` (modern); header `2025-11-25` bare (legacy); header `2026-07-28` bare (modern); header `3000-01-01` (modern); no method (not classified) | as listed |
| 24 | M `badIdIs32600` | L1 with `"id": null`; with `"id": {"a":1}` | `400` `-32600` "Invalid Request: id must be a string or number", `"id": null` |
| 25 | S `stage1-tools.sh` modern block (§7.5, 8 checks); `stage1-check.sh` two probes (§7.4) | against a local `notetaker-remote serve` with `--insecure-loopback` and `NR_ACCESS_TOKEN_FILE` | all PASS |

Rows 1–24 run three times under `scripts/verify.sh 3` (flake guard on the concurrent row).

## 11. Verification

### 11.1 Builder, before handing back

1. `cd Packages/RemoteServer && DEVELOPER_DIR=/Applications/Xcode-beta.app swift test --scratch-path ~/.cache/notetaker-build/RemoteServer` green (expect 161 existing + the new rows).
2. `swiftformat --lint .` clean at the repo root.
3. `scripts/verify.sh 3 --install` passes (all packages ×3, both app builds, launch check).
4. Local black-box: build `notetaker-remote` from the package (`swift build --product notetaker-remote --scratch-path ~/.cache/notetaker-build/RemoteServer`), run `serve` against a scratch replica with a test authenticator as `OAuthProbeScriptTests`/`stage1-check.sh --insecure-loopback` already do, and run (a) `stage1-check.sh http://127.0.0.1:<port> --insecure-loopback --expect-public-url https://nr-test.ts.net` and (b) `NR_ACCESS_TOKEN_FILE=<file> stage1-tools.sh http://127.0.0.1:<port> <client id> --insecure-loopback`; paste the PASS/FAIL summary lines (not the bodies) into the handback. If the local serve path needs a token the builder cannot mint without Google, say so and run only (a) plus the `swift test` rows; the orchestrator then runs (b) on the tailnet.
5. `git status` shows only: the new `ModernPath.swift`, `HTTPTestHarness.swift`, `ModernPathTests.swift`; modified `RemoteMCPServer.swift`, `App.swift` (two lines), `HTTPTests.swift`, `ToolGatewayTests.swift`, `stage1-check.sh`, `stage1-tools.sh`, `00-security-design.md`, `RUNBOOK.md`. Nothing else.

### 11.2 Orchestrator, before merge

CI `linux-packages` green on the branch (RemoteServer on `swift:6.4-noble`); the §6.2 capture table filled in; the critic's §8 checklist.

### 11.3 Orchestrator, after deploy (§12)

Capture again with the new binary (RUNBOOK 3.7); `audit-summary.sh`; H8 (optional, staging only — never on production: a build with `supportedVersions = ["2099-01-01"]` to see whether a client retries from `supported`; skip unless a client misbehaves).

### 11.4 The capture command (header-only; records methods, versions, header names, status codes — nothing else)

On CT 120 as root, `unset HISTFILE` first:

```bash
timeout 600 tcpdump -i lo -l -A -s 0 'tcp port 8787' 2>/dev/null \
  | grep -aoE '^(POST /mcp|HTTP/1\.[01] [0-9]{3})|^(MCP-Protocol-Version|Mcp-Method|Mcp-Name|Mcp-Session-Id|Last-Event-ID|Accept|Content-Type): [^\r]{0,64}|"method":"[^"]{1,40}"|"io\.modelcontextprotocol/protocolVersion":"[^"]{1,20}"|"io\.modelcontextprotocol/(clientCapabilities|clientInfo|logLevel)"|"id":("|[0-9])' \
  | tee /root/capture-2026-headers.txt
```

`-o` prints only the matched fragments: no `Authorization` line (not in the pattern), no arguments, no results, no `clientInfo` values, and for `id` only the opening quote or first digit (type, not value). Fields to record in PROGRESS per client: the ordered list of `method` values, the header version, each status code, which `Mcp-*`/`_meta` names were present, and whether `Mcp-Name` was sentinel-encoded. Delete `/root/capture-2026-headers.txt` after the row is written (the offsite tar covers `/root`).

## 12. Rollout (orchestrator; a user gate at each ⏸)

1. ⏸ Merge after §11.2. Push the branch; note `<REF>`.
2. **[host]** Build in a throwaway CT per RUNBOOK 1.2 with `--swift-version 6.4.2` (PROGRESS 221: the script default's tarball URL 404s against the 6.4.2 checksum); record `BINARY`/`SHA256`; all package tests pass inside the build CT (this is the Linux proof in addition to CI).
3. **[ct]** `bash /root/build/deploy.sh --yes --binary /root/notetaker-remote --sha256 <hex>`; `deploy.sh` keeps the previous binary as `/usr/local/bin/notetaker-remote.prev` **[verified: deploy.sh 41]**. Expect `systemctl is-active notetaker-remote` active, `status` shows `ready, <N> notes`, 7 Funnel routes unchanged (`nr-serve-routes status`), `audit-replica` clean.
4. **[mac]** `scripts/remote-vault/stage2-check.sh https://<NODE>.<TAILNET>.ts.net` from off the tailnet (the two new probes included), then wait 60 s for the tarpit; `stage1-tools.sh` over the tailnet with a fresh login (modern block passes against production).
5. ⏸ **Post-deploy capture (RUNBOOK 3.7):** Duet and claude.ai back to back, each asked for `vault_overview`. Expect `server/discover → 200`, no `initialize` from a 2026 client, `tool.call ok` lines for both with `client_id`/`token_family` (H10). The two clients' calls land within the same minute so the audit shows them adjacent, as PROGRESS 221 did for the legacy fix.
6. Rollback at any failed step: `cp -p /usr/local/bin/notetaker-remote.prev /usr/local/bin/notetaker-remote && systemctl restart notetaker-remote`; re-run step 5's capture; record both outcomes.
7. Cleanup as PROGRESS 221: deploy key removed from GitHub, staging copies removed from `/root`, build CT destroyed, orphan `vm-<BID>-disk-*` LVs removed, capture file deleted.
8. PROGRESS row (orchestrator): spec, files, test counts, binary hash, capture summary per client, any §6.2 adjustment made.

## 13. Non-goals

No OAuth change of any kind (`iss` is already emitted and advertised; no CIMD, no DCR, no `/register`, no `application_type`, no metadata change); no Roots, Sampling, Logging, `logging/setLevel`, `notifications/message`; no tasks extension, no MRTR (`input_required` is never produced), no `subscriptions/listen` implementation and no SSE anywhere on the modern path; no `x-mcp-header` annotation on any tool; no `Mcp-Param-*` validation; no swift-sdk fork, patch or version bump; no change to MCPKit, the stdio server, `ToolGateway`, `RemoteToolCatalog`, the audit schema, the rate limiter, the replica watcher or the kill switch; no Swift change outside the files listed in §11.1 item 5; no new public route or prefix in `serve-routes.sh`; no CT/host/nftables/systemd change.

## 14. Rules for the builder

- Read nothing under `~/.ssh`, `~/.claude.json`, any `.env`, `/etc/notetaker-remote/env`, `~/Library/Application Support/Notetaker/RemoteExport/`; never run anything against hildanet (192.168.5.100), CT 120, the tailnet node or Google. All testing is local (`swift test`, a local `serve`).
- Toolchain and build products exactly as CLAUDE.md: prefix with `DEVELOPER_DIR=/Applications/Xcode-beta.app`; scratch path `~/.cache/notetaker-build/RemoteServer` (or another dir under `~/.cache`); never create `build/` or `.build/` inside the repo.
- Pre-existing uncommitted files that must **not** be touched, staged or reverted: `Packages/ConversionKit/Sources/ConversionKit/PythonEngineConverter.swift` (modified), `Packages/EditorKit/Package.resolved` (modified), `Notetaker 5.xcodeproj/` (untracked), `specs/mcp-2026/00-research.md` and this file (untracked; read-only for the builder).
- Do not commit; the orchestrator commits one step with the PROGRESS row. Do not edit `PROGRESS.md`, `PLAN.md`, `CLAUDE.md`.
- When a §6.2 capture result arrives mid-build as a one-line instruction from the orchestrator, apply exactly that line and add its test row; do not widen it.
- If `MCP.HTTPResponse`'s 200-only `.data` case forces a different hook shape than §7.2 describes, keep the constraint ("`App.swift` changes limited to the two call-site lines; modern error bodies carry their JSON on a non-200 status") and describe the deviation in the handback.

## 15. Flagged ambiguities and the smallest proposed fix

1. **Non-200 bodies through `MCP.HTTPResponse`.** `.error(statusCode:…)` cannot carry `data` or a non-null id **[verified]**; `.data` is always 200. Proposed (§7.2): a second entry point on `RemoteMCPServer` returning `(status, headers, body)` consumed by `MCPEndpoint`; `handle(_:)` stays for the SDK path and existing tests. If the builder finds a two-line alternative (e.g. an `extraHeaders`-free wrapper type the SDK already exposes), take it and say so.
2. **`clientCapabilities` on `server/discover`.** Required by the `_meta` MUST, present in the discover page's example; whether Duet/claude.ai send it is capture question H1/H5. Fix if absent: relax step 2 for `server/discover` only (§6.2). Not relaxed by default because a strict `-32602` is a recognised modern error and cannot make a client regress to worse than today.
3. **`subscriptions/listen` and `ping` → 404.** Decided (§6.1), capture-gated (H3/H4). If a client aborts, the fix is a new spec, not a tweak.
4. **`cacheScope: "private"` vs `"public"`.** Both compliant; `private` chosen as fail-closed (the catalog is identical for every user, but the only user is one person behind OAuth; nothing is gained by `public`). One-constant change if ever wanted.
5. **`ttlMs: 3600000`.** A client may cache the catalog for an hour across a deploy that changes a description; the tool *set* never changes without a security-design change, so this is harmless. `0` would also be compliant; not chosen because it defeats the point of the hint.
6. **Unknown `cursor` → `400 -32602`.** The spec gives no status for pagination errors; §0's one-rule keeps it `400`. No known client sends a cursor to a single-page server.
7. **Modern path and the global tool bucket.** `server/discover` and `tools/list` consume a token from the 60/min bucket exactly as legacy `initialize`/`tools/list` do today. Unchanged on purpose (one limiter, one counter); if a 2026 client re-probes `discover` aggressively the capture (H1) will show it and the fix is a limiter exemption spec'd separately.
8. **Header value trimming.** HTTP OWS trimming is applied to `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` before comparison (python-sdk #3763). A padded `Mcp-Name` that was *meant* to be padded would have been sentinel-encoded by a conformant client, so trimming cannot cause a false match.
9. **Issuer-rename operational note** (research §c.4: renaming the Tailscale node changes the OAuth issuer and forces a reconnect) is RUNBOOK material unrelated to this change; not added here. Suggest one line under RUNBOOK 3.5 in a later doc pass.
10. **Test harness refactor.** Moving `withApp` and friends into `HTTPTestHarness.swift` touches `HTTPTests.swift` beyond the one extended test, but only with private forwarders. Alternative with zero `HTTPTests.swift` churn: duplicate the 30-line harness in `ModernPathTests.swift`; rejected to keep one harness.

---

## Summary

One Sonnet builder adds `ModernPath.swift` (a ~300-line router inside `RemoteMCPServer.handle`) that answers MCP 2026-07-28 requests — `server/discover`, `tools/list` with `ttlMs`/`cacheScope`, `tools/call` through the unchanged `ToolGateway` — and the exact 2026 error shapes (`400 -32022` with `supported: ["2026-07-28"]`, `400 -32020` header mismatch with base64 `Mcp-Name` decoding, `400 -32602` for missing `_meta`, `404 -32601` for everything else including `subscriptions/listen` and `ping`), while `initialize` and all legacy traffic keep the swift-sdk path byte-for-byte. Classification: `initialize` is always legacy; `server/discover`/`subscriptions/listen`, a `_meta` `protocolVersion` key, or a `>= 2026-07-28` header make a request modern; modern notifications get `202`. Tests: 24 rows in a new `ModernPathTests.swift` plus a shared harness, one extended legacy test, one catalog test, and modern blocks in `stage1-check.sh`/`stage1-tools.sh`. Docs: dated §10 in the security design, RUNBOOK drill 3.7. Invariants: no new route, no new tool, auth/Host/rate-limit order unchanged, identical audit lines, kill switch unchanged, no bodies or tokens in logs or errors. Four research corrections (notification 400→202, `_meta`-key classification, value-not-byte tool equality, one status rule) are recorded; `clientCapabilities` on discover, `listen` and `ping` are gated on the live header-only capture before merge; rollout is build-CT 6.4.2 → `deploy.sh` → `.prev` rollback → Duet + claude.ai capture.
