// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VaultClassifier",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VaultClassifierCore", targets: ["VaultClassifierCore"]),
        .executable(name: "VaultClassifierApp", targets: ["VaultClassifierApp"]),
        .executable(name: "VaultClassifierNativeHost", targets: ["VaultClassifierNativeHost"]),
    ],
    targets: [
        .target(
            name: "VaultClassifierCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "VaultClassifierApp",
            dependencies: ["VaultClassifierCore"]
        ),
        .executableTarget(
            name: "VaultClassifierNativeHost",
            dependencies: ["VaultClassifierCore"]
        ),
        .testTarget(
            name: "VaultClassifierCoreTests",
            dependencies: ["VaultClassifierCore"]
        ),
    ]
)
