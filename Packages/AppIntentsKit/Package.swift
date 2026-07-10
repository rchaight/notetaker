// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppIntentsKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "AppIntentsKit", targets: ["AppIntentsKit"])],
    targets: [
        .target(name: "AppIntentsKit"),
        .testTarget(name: "AppIntentsKitTests", dependencies: ["AppIntentsKit"]),
    ]
)
