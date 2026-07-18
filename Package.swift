// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VaultClassifier",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VaultClassifierCore", targets: ["VaultClassifierCore"]),
        .executable(name: "VaultClassifierApp", targets: ["VaultClassifierApp"]),
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
