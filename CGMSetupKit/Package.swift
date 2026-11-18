// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CGMSetupKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CGMSetupKit", targets: ["CGMSetupKit"])],
    targets: [
        .target(name: "CGMSetupKit", resources: [.process("Resources")]),
        .testTarget(name: "CGMSetupKitTests", dependencies: ["CGMSetupKit"])
    ]
)
