// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PrivacyKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PrivacyKit", targets: ["PrivacyKit"]),
        .library(name: "PrivacyAppKit", targets: ["PrivacyAppKit"])
    ],
    targets: [
        .target(name: "PrivacyKit", resources: [.process("Resources")]),
        .target(name: "PrivacyAppKit", dependencies: ["PrivacyKit"], resources: [.process("Resources")]),
        .testTarget(name: "PrivacyKitTests", dependencies: ["PrivacyKit", "PrivacyAppKit"])
    ]
)
