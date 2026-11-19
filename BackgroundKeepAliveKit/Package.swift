// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BackgroundKeepAliveKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "BackgroundKeepAliveKit", targets: ["BackgroundKeepAliveKit"])],
    targets: [
        .target(name: "BackgroundKeepAliveKit", resources: [.process("Resources")]),
        .testTarget(name: "BackgroundKeepAliveKitTests", dependencies: ["BackgroundKeepAliveKit"])
    ]
)
