// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConversionKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "ConversionKit", targets: ["ConversionKit"])],
    targets: [
        .target(name: "ConversionKit"),
        .testTarget(name: "ConversionKitTests", dependencies: ["ConversionKit"]),
    ]
)
