import Foundation
import HTTPTypes
import Hummingbird
import MCP

/// Builds the Hummingbird application: middleware order is request-size limit
/// (413) → Host allowlist (421) → route. Error mapping wraps all of it so no
/// response ever carries a framework error body or a `Server` header.
public enum RemoteApp {
    public static let maxBodyBytes = 64 * 1024

    /// Extra routes (spec 07 adds the OAuth endpoints here without touching this router).
    public typealias RouteContributor = @Sendable (Router<BasicRequestContext>) -> Void

    public static func build(
        config: RemoteConfig,
        authenticator: any BearerAuthenticator,
        mcp: RemoteMCPServer,
        limiter: RateLimiter,
        audit: AuditLog?,
        extraRoutes: RouteContributor = { _ in }
    ) -> some ApplicationProtocol {
        let router = Router<BasicRequestContext>()
        router.add(middleware: EmptyErrorBodyMiddleware())
        router.add(middleware: BodyLimitMiddleware(limit: maxBodyBytes))
        router.add(middleware: HostAllowlistMiddleware(allowed: config.allowedHosts))

        let endpoint = MCPEndpoint(
            config: config, authenticator: authenticator, mcp: mcp, limiter: limiter, audit: audit
        )
        router.post("/mcp") { request, _ in await endpoint.handle(request) }
        for method in [HTTPRequest.Method.get, .delete, .put, .patch] {
            router.on("/mcp", method: method) { _, _ in
                var headers = HTTPFields()
                headers[.allow] = "POST"
                return Response(status: .methodNotAllowed, headers: headers)
            }
        }

        let metadata = ProtectedResourceMetadata.document(for: config)
        for path in ["/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"] {
            router.get(RouterPath(path)) { _, _ in
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                headers[.cacheControl] = "max-age=3600"
                return Response(
                    status: .ok,
                    headers: headers,
                    body: ResponseBody(byteBuffer: ByteBuffer(bytes: metadata))
                )
            }
        }

        router.get("/healthz") { _, _ in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            return Response(
                status: .ok,
                headers: headers,
                body: ResponseBody(byteBuffer: ByteBuffer(string: "{\"ok\":true}"))
            )
        }

        extraRoutes(router)

        return Application(
            router: router,
            configuration: ApplicationConfiguration(
                address: .hostname(config.bindHost, port: config.bindPort),
                serverName: nil
            )
        )
    }
}

// MARK: - Middleware

/// Turns every thrown error (including the router's 404) into an empty body.
struct EmptyErrorBodyMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext

    func handle(
        _ request: Request, context: Context, next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as any HTTPResponseError {
            return Response(status: error.status)
        } catch {
            return Response(status: .internalServerError)
        }
    }
}

/// 64 KB request-body ceiling: a `Content-Length` precheck, then a bounded read
/// (chunked bodies have no length to check). The collected body replaces the stream.
struct BodyLimitMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let limit: Int

    func handle(
        _ request: Request, context: Context, next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if let declared = request.headers[.contentLength].flatMap({ Int($0) }), declared > limit {
            return Response(status: .contentTooLarge)
        }
        var request = request
        guard request.method == .post || request.method == .put || request.method == .patch else {
            return try await next(request, context)
        }
        do {
            _ = try await request.collectBody(upTo: limit)
        } catch {
            return Response(status: .contentTooLarge)
        }
        return try await next(request, context)
    }
}

/// `Host` allowlist (421 Misdirected Request). Both the HTTP/1.1 `Host` field and
/// the `:authority` the server codec derives from it must match.
struct HostAllowlistMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let allowed: [String]

    func handle(
        _ request: Request, context: Context, next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let candidates = [request.head.authority, request.headers[HTTPField.Name("Host")!]].compactMap(\.self)
        guard !candidates.isEmpty, candidates.allSatisfy({ Self.matches($0, allowed: allowed) }) else {
            return Response(status: .misdirectedRequest)
        }
        return try await next(request, context)
    }

    static func matches(_ host: String, allowed: [String]) -> Bool {
        let value = host.lowercased()
        for pattern in allowed {
            if pattern == value {
                return true
            }
            if pattern.hasSuffix(":*") {
                let base = String(pattern.dropLast(2))
                if value == base {
                    return true
                }
                if value.hasPrefix(base + ":"), Int(value.dropFirst(base.count + 1)) != nil {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - POST /mcp

struct MCPEndpoint: Sendable {
    let config: RemoteConfig
    let authenticator: any BearerAuthenticator
    let mcp: RemoteMCPServer
    let limiter: RateLimiter
    let audit: AuditLog?

    func handle(_ request: Request) async -> Response {
        let ip = Self.clientIP(of: request, trustForwardedFor: config.trustForwardedFor)
        let limiterKey = ip ?? "global"

        // 1. Authenticate. A valid token is never locked out by someone else's
        //    failures (with no trusted client IP the tarpit key is global).
        let principal: AuthenticatedPrincipal
        switch await authenticator.authenticate(authorizationHeader: request.headers[.authorization]) {
        case let .authenticated(found):
            principal = found
        case .missing:
            return await reject(key: limiterKey, ip: ip, event: "auth.missing", description: nil)
        case let .denied(description):
            return await reject(key: limiterKey, ip: ip, event: "auth.denied", description: description)
        }

        // 2. Optional Anthropic egress allowlist (only meaningful with a trusted client IP).
        if config.anthropicIPAllowlist, let ip, !AnthropicNetwork.contains(ip) {
            await audit?.record(AuditEvent(
                event: "auth.denied", status: "403", clientID: principal.clientID,
                tokenFamily: principal.tokenFamily, ip: ip, reason: "ip not allowed"
            ))
            return Response(status: .forbidden)
        }

        // 3. Global tool bucket.
        if case let .limited(retryAfter) = await limiter.admitToolCall() {
            await audit?.record(AuditEvent(
                event: "rate.limited", status: "429", clientID: principal.clientID,
                tokenFamily: principal.tokenFamily, ip: ip, reason: "tool buckets"
            ))
            return Self.tooManyRequests(retryAfter: retryAfter)
        }

        // 4. Hand to the SDK transport. The bearer token is not forwarded, and
        //    any client-supplied internal header is dropped before ours are set.
        var headers = InternalHeaders.strip(Self.flatten(request.headers))
        headers = headers.filter { $0.key.lowercased() != "authorization" }
        if let clientID = principal.clientID {
            headers[InternalHeaders.clientID] = clientID
        }
        if let family = principal.tokenFamily {
            headers[InternalHeaders.tokenFamily] = family
        }
        if let ip {
            headers[InternalHeaders.clientIP] = ip
        }

        let body = await (try? request.body.collect(upTo: RemoteApp.maxBodyBytes)).map { Data($0.readableBytesView) }
        let response = await mcp.handle(MCP.HTTPRequest(method: "POST", headers: headers, body: body, path: "/mcp"))
        return Self.map(response)
    }

    private func reject(key: String, ip: String?, event: String, description: String?) async -> Response {
        if case let .limited(retryAfter) = await limiter.isTarpitted(key: key) {
            return Self.tooManyRequests(retryAfter: retryAfter)
        }
        let tripped = await limiter.recordAuthFailure(key: key)
        await audit?.record(AuditEvent(event: event, status: "401", ip: ip))
        if tripped {
            await audit?.record(AuditEvent(event: "auth.tarpit", status: "429", ip: ip, reason: "401 window exceeded"))
        }
        var headers = HTTPFields()
        headers[.wwwAuthenticate] = UnauthorizedChallenge.wwwAuthenticate(
            metadataURL: config.metadataURL, description: description
        )
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        return Response(
            status: .unauthorized, headers: headers,
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: UnauthorizedChallenge.body))
        )
    }

    static func tooManyRequests(retryAfter: Int) -> Response {
        var headers = HTTPFields()
        headers[.retryAfter] = String(retryAfter)
        headers[.cacheControl] = "no-store"
        return Response(status: .tooManyRequests, headers: headers)
    }

    static func map(_ response: HTTPMessageResponse) -> Response {
        var headers = HTTPFields()
        for (name, value) in response.headers {
            if let field = HTTPField.Name(name) {
                headers[field] = value
            }
        }
        switch response {
        case .stream:
            // Stateless mode never streams; if it somehow does, refuse rather than hang.
            return Response(status: .internalServerError)
        default:
            let status = HTTPResponse.Status(code: response.statusCode)
            guard let data = response.bodyData else { return Response(status: status, headers: headers) }
            return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
        }
    }

    static func flatten(_ fields: HTTPFields) -> [String: String] {
        var out: [String: String] = [:]
        for field in fields {
            let name = field.name.rawName
            out[name] = out[name].map { $0 + ", " + field.value } ?? field.value
        }
        return out
    }

    /// First `X-Forwarded-For` address, only when explicitly trusted and well-formed.
    static func clientIP(of request: Request, trustForwardedFor: Bool) -> String? {
        guard trustForwardedFor, let header = request.headers[HTTPField.Name("X-Forwarded-For")!] else { return nil }
        let first = header.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let allowed = Set("0123456789abcdefABCDEF.:")
        guard !first.isEmpty, first.count <= 45, first.allSatisfy({ allowed.contains($0) }) else { return nil }
        return first
    }
}

typealias HTTPMessageResponse = MCP.HTTPResponse

enum AnthropicNetwork {
    /// 160.79.104.0/21 (Anthropic's published egress range). IPv6 is not allowed.
    static func contains(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return false }
        let value = parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
        let network: UInt32 = 160 << 24 | 79 << 16 | 104 << 8
        return value & 0xFFFF_F800 == network
    }
}
