// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskEngine",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "TaskEngine", targets: ["TaskEngine"])],
    targets: [
        .target(name: "TaskEngine"),
        .testTarget(name: "TaskEngineTests", dependencies: ["TaskEngine"]),
    ]
)
