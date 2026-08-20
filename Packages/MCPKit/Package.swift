// swift-tools-version: 6.0
import PackageDescription

// macOS-only: the server is a spawnable CLI bundled in Notetaker.app, and
// iOS can't host one. The MCP SDK's own floor is macOS 13; ours matches the
// app so IndexKit/AIKit resolve.
let package = Package(
    name: "MCPKit",
    platforms: [.macOS("26.0")],
    products: [.library(name: "MCPKit", targets: ["MCPKit"])],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        .package(path: "../IndexKit"),
        .package(path: "../MarkdownKit"),
        .package(path: "../TaskEngine"),
        .package(path: "../AIKit"),
    ],
    targets: [
        .target(
            name: "MCPKit",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "IndexKit",
                "MarkdownKit",
                "TaskEngine",
                "AIKit",
            ]
        ),
        .testTarget(
            name: "MCPKitTests",
            dependencies: ["MCPKit", "IndexKit", "AIKit", .product(name: "MCP", package: "swift-sdk")]
        ),
    ]
)
