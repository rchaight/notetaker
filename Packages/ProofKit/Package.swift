// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProofKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "ProofKit", targets: ["ProofKit"])],
    // No package dependencies on purpose: exclusions (code spans, #tags,
    // task tokens…) are INJECTED as plain NSRanges by the caller rather
    // than computed in here. Spec 01 (running concurrently) is adding
    // EditorKit's ProofingExclusions oracle in a separate worktree — it
    // doesn't exist yet here, and even once merged the right layering is
    // the app/orchestrator calling it and handing ProofKit the ranges, the
    // same way AIKit's OllamaProvider never reaches into SecurityKit for
    // its own Keychain-stored URL. Pure + dependency-free keeps this
    // package trivially testable.
    targets: [
        .target(name: "ProofKit"),
        .testTarget(name: "ProofKitTests", dependencies: ["ProofKit"]),
    ]
)
