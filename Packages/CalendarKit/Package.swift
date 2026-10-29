// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalendarKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "CalendarKit", targets: ["CalendarKit"])],
    targets: [
        .target(name: "CalendarKit"),
        .testTarget(name: "CalendarKitTests", dependencies: ["CalendarKit"]),
    ]
)
