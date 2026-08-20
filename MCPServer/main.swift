import Foundation
import MCPKit

/// Thin main: everything testable lives in MCPKit.
let status = await NotetakerMCPLauncher.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
