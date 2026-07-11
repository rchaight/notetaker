// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EditorKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "EditorKit", targets: ["EditorKit"])],
    dependencies: [
        .package(path: "../MarkdownKit"),
    ],
    targets: [
        .target(name: "EditorKit", dependencies: ["MarkdownKit"]),
        .testTarget(name: "EditorKitTests", dependencies: ["EditorKit"]),
    ]
)
