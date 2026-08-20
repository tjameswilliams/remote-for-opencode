// swift-tools-version: 5.9
import PackageDescription

/// Everything both apps share: the phone⇄Mac protocol, the transport that
/// carries it, pairing, and the rendering primitives built on top.
///
/// A package rather than a folder of sources for three reasons: it can be
/// unit-tested on its own, it forces the public surface to be deliberate,
/// and it's what a third client — the desktop app on the roadmap — would
/// depend on without dragging an app target along with it.
let package = Package(
    name: "RemoteKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RemoteKit", targets: ["RemoteKit"]),
    ],
    dependencies: [
        // Syntax highlighting for code the agent writes (highlight.js via
        // JavaScriptCore). Pinned exactly, like Sparkle: dependencies move
        // when we decide, not when they release.
        .package(url: "https://github.com/raspu/Highlightr", exact: "2.3.0"),
    ],
    targets: [
        .target(name: "RemoteKit", dependencies: ["Highlightr"]),
        .testTarget(name: "RemoteKitTests", dependencies: ["RemoteKit"]),
    ]
)
