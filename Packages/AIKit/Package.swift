// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "AIKit", targets: ["AIKit"])],
    dependencies: [
        .package(path: "../TaskEngine"),
    ],
    targets: [
        .target(name: "AIKit", dependencies: ["TaskEngine"]),
        .testTarget(name: "AIKitTests", dependencies: ["AIKit"]),
    ]
)
