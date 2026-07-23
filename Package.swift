// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VaultClassifier",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VaultClassifierCore", targets: ["VaultClassifierCore"]),
        .executable(name: "VaultClassifierApp", targets: ["VaultClassifierApp"]),
        .executable(name: "VaultLocalHubNativeHost", targets: ["VaultLocalHubNativeHost"]),
    ],
    targets: [
        .target(
            name: "VaultClassifierCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "VaultClassifierApp",
            dependencies: ["VaultClassifierCore"],
            resources: [.copy("WebAssets")]
        ),
        .executableTarget(
            name: "VaultLocalHubNativeHost",
            dependencies: ["VaultClassifierCore"]
        ),
        .testTarget(
            name: "VaultClassifierCoreTests",
            dependencies: ["VaultClassifierCore"]
        ),
        .testTarget(
            name: "VaultClassifierAppTests",
            dependencies: ["VaultClassifierApp", "VaultClassifierCore"]
        ),
    ]
)
