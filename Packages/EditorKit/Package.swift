// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EditorKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "EditorKit", targets: ["EditorKit"])],
    dependencies: [
        .package(path: "../MarkdownKit"),
        .package(path: "../TaskEngine"),
    ],
    targets: [
        .target(name: "EditorKit", dependencies: ["MarkdownKit", "TaskEngine"]),
        .testTarget(name: "EditorKitTests", dependencies: ["EditorKit"]),
    ]
)
