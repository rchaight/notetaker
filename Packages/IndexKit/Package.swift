// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IndexKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "IndexKit", targets: ["IndexKit"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3"),
        .package(path: "../MarkdownKit"),
        .package(path: "../TaskEngine"),
        .package(path: "../ProjectKit"),
    ],
    targets: [
        .target(
            name: "IndexKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                "MarkdownKit",
                "TaskEngine",
                "ProjectKit",
            ]
        ),
        .testTarget(name: "IndexKitTests", dependencies: ["IndexKit"]),
    ]
)
