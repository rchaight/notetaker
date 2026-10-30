import Foundation
import RemoteServerCore

// Argument dispatch only; everything testable lives in RemoteServerCore.
// `authenticator: nil` selects the spec 07 OAuth authorization server: `serve`
// builds the token store and guards `/mcp` with its `TokenAuthenticator`
// (it needs the store, which needs the parsed config — hence built there).
await exit(Commands.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment,
    authenticator: nil
))
