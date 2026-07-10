// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EditorKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "EditorKit", targets: ["EditorKit"])],
    targets: [
        .target(name: "EditorKit"),
        .testTarget(name: "EditorKitTests", dependencies: ["EditorKit"]),
    ]
)
