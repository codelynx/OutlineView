// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "OutlineView",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "OutlineView", targets: ["OutlineView"]),
    ],
    targets: [
        .target(name: "OutlineView"),
        .testTarget(name: "OutlineViewTests", dependencies: ["OutlineView"]),
    ],
    swiftLanguageModes: [.v6]
)
