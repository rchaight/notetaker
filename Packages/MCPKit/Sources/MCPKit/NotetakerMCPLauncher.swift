import Foundation
import MCP

/// Process-level entry point. `MCPServer/main.swift` is nothing but a call
/// into here, so everything below stays under `swift test`.
public enum NotetakerMCPLauncher {
    public static let usage = """
    notetaker-mcp — read-only MCP server over your Notetaker vault.

    Claude Code / Claude Desktop launch this over stdio; you rarely run it
    by hand. To register it:

      claude mcp add notetaker -- /Applications/Notetaker.app/Contents/MacOS/notetaker-mcp

    Options:
      --vault <path>   Serve this folder instead of the active vault.
      --index <path>   Use this GRDB index file (default: the app's).
      --version        Print the version and exit.
      -h, --help       Print this help and exit.

    Tools: vault_overview, list_folder, read_note, search, tasks.
    The server never writes to the vault or to the index.
    """

    /// Returns a process exit code; never traps.
    public static func run(arguments: [String]) async -> Int32 {
        if arguments.contains("-h") || arguments.contains("--help") {
            print(usage)
            return 0
        }
        if arguments.contains("--version") {
            print("\(NotetakerMCPServer.serverName) \(NotetakerMCPServer.version)")
            return 0
        }

        let location: VaultLocation
        do {
            location = try VaultLocator.resolve(arguments: arguments)
        } catch {
            report("notetaker-mcp: \(error)")
            return 1
        }

        let service = VaultService(location: location)
        report("notetaker-mcp: serving \(location.root.path) (index: \(service.indexStatus))")

        let server = await NotetakerMCPServer.make(service: service)
        do {
            try await server.start(transport: StdioTransport())
        } catch {
            report("notetaker-mcp: transport failed: \(error)")
            return 1
        }
        await server.waitUntilCompleted()
        return 0
    }

    /// stdout belongs to JSON-RPC; diagnostics go to stderr or nowhere.
    private static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
