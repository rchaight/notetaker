// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarkdownKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "MarkdownKit", targets: ["MarkdownKit"])],
    targets: [
        .target(name: "MarkdownKit"),
        .testTarget(name: "MarkdownKitTests", dependencies: ["MarkdownKit"]),
    ]
)
