// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SecurityKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "SecurityKit", targets: ["SecurityKit"])],
    targets: [
        .target(name: "SecurityKit"),
        .testTarget(name: "SecurityKitTests", dependencies: ["SecurityKit"]),
    ]
)
