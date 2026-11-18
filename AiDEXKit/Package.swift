// swift-tools-version: 5.9
import PackageDescription

// A deliberately small, independent package for the display-only AiDEX
// foreground probe. The decoder, serial matcher and session state machine are
// Foundation-only so they can be tested on macOS; the CoreBluetooth transport
// and SwiftUI screen compile only for iOS.
let package = Package(
    name: "AiDEXKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "AiDEXKit", targets: ["AiDEXKit"])
    ],
    targets: [
        .target(
            name: "AiDEXKit",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AiDEXKitTests",
            dependencies: ["AiDEXKit"]
        )
    ]
)
