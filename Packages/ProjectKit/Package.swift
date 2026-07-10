// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "ProjectKit", targets: ["ProjectKit"])],
    targets: [
        .target(name: "ProjectKit"),
        .testTarget(name: "ProjectKitTests", dependencies: ["ProjectKit"]),
    ]
)
