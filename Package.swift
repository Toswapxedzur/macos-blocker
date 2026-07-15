// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "macosBlocker",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "MacBlockerCore", targets: ["MacBlockerCore"]),
        .library(name: "MacBlockerScreenTime", targets: ["MacBlockerScreenTime"]),
        .library(name: "MacBlockerMacControl", targets: ["MacBlockerMacControl"]),
        .library(name: "MacBlockerAppFeature", targets: ["MacBlockerAppFeature"]),
        .library(name: "MacBlockerWebUI", targets: ["MacBlockerWebUI"]),
        .executable(name: "MacBlockerPanel", targets: ["MacBlockerPanel"])
    ],
    targets: [
        .target(
            name: "MacBlockerCore",
            resources: [
                // Whole folder: custom-rule-runtime.js (iOS no-op-DOM engine),
                // plus helpers.js + event-sandbox.js (the verbatim, intent-
                // emitting browser engine the Safari bridge runs in JSC).
                .copy("Resources")
            ]
        ),
        .target(
            name: "MacBlockerScreenTime",
            dependencies: ["MacBlockerCore"]
        ),
        .target(
            name: "MacBlockerMacControl",
            dependencies: ["MacBlockerCore"],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedLibrary("EndpointSecurity", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "MacBlockerWebUI",
            dependencies: ["MacBlockerCore"],
            resources: [
                .copy("WebAssets")
            ]
        ),
        .target(
            name: "MacBlockerAppFeature",
            dependencies: [
                "MacBlockerCore",
                "MacBlockerScreenTime",
                "MacBlockerMacControl",
                "MacBlockerWebUI"
            ]
        ),
        .executableTarget(
            name: "MacBlockerPanel",
            dependencies: ["MacBlockerAppFeature"]
        ),
        .testTarget(
            name: "MacBlockerCoreTests",
            dependencies: ["MacBlockerCore"]
        ),
        .testTarget(
            name: "MacBlockerMacControlTests",
            dependencies: ["MacBlockerMacControl", "MacBlockerCore"]
        ),
        .testTarget(
            name: "MacBlockerAppFeatureTests",
            dependencies: ["MacBlockerAppFeature"]
        )
    ]
)
