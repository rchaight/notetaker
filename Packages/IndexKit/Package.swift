// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IndexKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "IndexKit", targets: ["IndexKit"])],
    targets: [
        .target(name: "IndexKit"),
        .testTarget(name: "IndexKitTests", dependencies: ["IndexKit"]),
    ]
)
