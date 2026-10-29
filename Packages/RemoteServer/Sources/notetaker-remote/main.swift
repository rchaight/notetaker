import Foundation
import RemoteServerCore

// Argument dispatch only; everything testable lives in RemoteServerCore.
// The default authenticator denies everything (spec 06 stage 1): spec 07
// replaces it here with the real OAuth bearer validator.
await exit(Commands.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment
))
