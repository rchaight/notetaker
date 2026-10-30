// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaultKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "VaultKit", targets: ["VaultKit"])],
    dependencies: [
        .package(path: "../MarkdownKit"),
        // Test-only: the leak tests build real LockedNoteFile envelopes.
        .package(path: "../SecurityKit"),
    ],
    targets: [
        .target(name: "VaultKit", dependencies: ["MarkdownKit"]),
        .testTarget(name: "VaultKitTests", dependencies: ["VaultKit", "SecurityKit"]),
    ]
)
