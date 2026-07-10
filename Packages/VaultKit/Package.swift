// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaultKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "VaultKit", targets: ["VaultKit"])],
    targets: [
        .target(name: "VaultKit"),
        .testTarget(name: "VaultKitTests", dependencies: ["VaultKit"]),
    ]
)
