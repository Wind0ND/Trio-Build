// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BackgroundKeepAliveKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "BackgroundKeepAliveKit", targets: ["BackgroundKeepAliveKit"])],
    targets: [
        .target(name: "BackgroundKeepAliveKit"),
        .testTarget(name: "BackgroundKeepAliveKitTests", dependencies: ["BackgroundKeepAliveKit"])
    ]
)
