// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadingKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "ReadingKit", targets: ["ReadingKit"])],
    dependencies: [
        .package(path: "../MarkdownKit"),
        .package(path: "../TaskEngine"),
        // Same version MarkdownKit resolves — no new dependency enters the
        // graph, ReadingKit just needs the AST types directly.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.0"),
    ],
    targets: [
        .target(
            name: "ReadingKit",
            dependencies: [
                "MarkdownKit",
                "TaskEngine",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(name: "ReadingKitTests", dependencies: ["ReadingKit"]),
    ]
)
