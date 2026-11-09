// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FretboardModeller",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FretboardApp", targets: ["FretboardApp"])
    ],
    targets: [
        .target(name: "FretboardKit"),
        .executableTarget(name: "FretboardApp", dependencies: ["FretboardKit"]),
        .testTarget(name: "FretboardKitTests", dependencies: ["FretboardKit"])
    ]
)
