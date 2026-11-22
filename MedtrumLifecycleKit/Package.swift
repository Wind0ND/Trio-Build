// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MedtrumLifecycleKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MedtrumLifecycleKit", targets: ["MedtrumLifecycleKit"])],
    targets: [
        .target(name: "MedtrumLifecycleKit"),
        .testTarget(name: "MedtrumLifecycleKitTests", dependencies: ["MedtrumLifecycleKit"])
    ]
)
