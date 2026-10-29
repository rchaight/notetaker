// swift-tools-version: 6.0
import PackageDescription

// `notetaker-remote`: the HTTP MCP server that runs in the Linux container
// over a read-only replica of the vault (specs/remote-vault/06). It is NOT
// linked into the app; the Mac gate builds and tests it like any package and
// the `linux-packages` CI job proves it on Linux.
let package = Package(
    name: "RemoteServer",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RemoteServerCore", targets: ["RemoteServerCore"]),
        .executable(name: "notetaker-remote", targets: ["notetaker-remote"]),
    ],
    dependencies: [
        .package(path: "../MCPKit"),
        .package(path: "../IndexKit"),
        .package(path: "../MarkdownKit"),
        .package(path: "../AIKit"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3"),
    ],
    targets: [
        .target(
            name: "RemoteServerCore",
            dependencies: [
                "MCPKit",
                "IndexKit",
                "MarkdownKit",
                "AIKit",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .executableTarget(
            name: "notetaker-remote",
            dependencies: ["RemoteServerCore"]
        ),
        .testTarget(
            name: "RemoteServerCoreTests",
            dependencies: [
                "RemoteServerCore",
                "MCPKit",
                "IndexKit",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
