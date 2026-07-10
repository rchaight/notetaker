// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarkdownKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "MarkdownKit", targets: ["MarkdownKit"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.0"),
    ],
    targets: [
        .target(
            name: "MarkdownKit",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .testTarget(name: "MarkdownKitTests", dependencies: ["MarkdownKit"]),
    ]
)
