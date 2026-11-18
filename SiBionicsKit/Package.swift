// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SiBionicsKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SiBionicsKit", targets: ["SiBionicsKit"])],
    dependencies: [.package(path: "../CGMSetupKit")],
    targets: [
        .target(name: "SiBionicsKit", dependencies: [.product(name: "CGMSetupKit", package: "CGMSetupKit")], resources: [.process("Resources")]),
        .testTarget(name: "SiBionicsKitTests", dependencies: ["SiBionicsKit"])
    ]
)
