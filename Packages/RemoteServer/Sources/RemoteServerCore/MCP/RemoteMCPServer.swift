import Foundation
import MCP
import MCPKit

/// Header names the HTTP layer stamps after authentication so the tool
/// gateway can attribute the audit line. Any client-supplied `x-nr-*` header
/// is stripped first (see `InternalHeaders.strip`).
enum InternalHeaders {
    static let prefix = "x-nr-"
    static let clientID = "X-NR-Client-Id"
    static let tokenFamily = "X-NR-Token-Family"
    static let clientIP = "X-NR-Client-Ip"

    static func strip(_ headers: [String: String]) -> [String: String] {
        headers.filter { !$0.key.lowercased().hasPrefix(prefix) }
    }
}

/// The MCP `Server` wired to a `StatelessHTTPServerTransport`. One instance
/// serves every request; there are no sessions.
public actor RemoteMCPServer {
    private let transport: StatelessHTTPServerTransport
    private let server: Server
    private var nextRequestNumber = 0

    public init(gateway: ToolGateway) async throws {
        let server = Server(
            name: NotetakerMCPServer.serverName,
            version: NotetakerMCPServer.version,
            instructions: RemoteToolCatalog.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: RemoteToolCatalog.tools())
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            let http = Server.currentHandlerContext?.httpContext
            let caller = ToolGateway.Caller(
                clientID: http?.header(InternalHeaders.clientID),
                tokenFamily: http?.header(InternalHeaders.tokenFamily),
                ip: http?.header(InternalHeaders.clientIP)
            )
            return await gateway.call(name: parameters.name, arguments: parameters.arguments ?? [:], caller: caller)
        }

        // Host/Origin allowlisting is the HTTP layer's job (the Host check replaces
        // OriginValidator.localhost()); only the protocol validators run here.
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ])
        )
        try await server.start(transport: transport)
        self.server = server
        self.transport = transport
    }

    public func stop() async {
        await server.stop()
    }

    /// The stateless transport correlates responses by JSON-RPC id alone, so two
    /// clients that both send `id: 1` at once would clobber each other's waiter
    /// and one request would hang. Give every request a unique wire id and put
    /// the caller's own id back on the way out.
    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              var message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let original = message["id"], original is String || original is NSNumber
        else {
            return await transport.handleRequest(request)
        }
        nextRequestNumber += 1
        message["id"] = "nr-\(nextRequestNumber)"
        guard let rewritten = try? JSONSerialization.data(withJSONObject: message) else {
            return await transport.handleRequest(request)
        }
        let response = await transport.handleRequest(
            HTTPRequest(method: request.method, headers: request.headers, body: rewritten, path: request.path)
        )
        guard case let .data(data, headers) = response,
              var reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return response }
        reply["id"] = original
        guard let restored = try? JSONSerialization.data(
            withJSONObject: reply, options: [.withoutEscapingSlashes]
        ) else { return response }
        return .data(restored, headers: headers)
    }
}
