// swift-tools-version: 5.9

import PackageDescription
import Foundation

let package = Package(
    name: "macosBlocker",
    platforms: [
        .macOS("13.3")
    ],
    products: [
        .library(name: "MacBlockerCore", targets: ["MacBlockerCore"]),
        .library(name: "MacBlockerMacControl", targets: ["MacBlockerMacControl"]),
        .library(name: "MacBlockerAppFeature", targets: ["MacBlockerAppFeature"]),
        .library(name: "MacBlockerWebUI", targets: ["MacBlockerWebUI"]),
        .executable(name: "MacBlockerPanel", targets: ["MacBlockerPanel"])
    ],
    dependencies: [
        // The Vault Classifier component (on-device tagging + its page). It lives
        // in this repository under classifier/; its portable service also powers Windows.
        .package(path: "classifier")
    ],
    targets: [
        .target(
            name: "MacBlockerCore",
            dependencies: [.product(name: "VaultActivityCore", package: "classifier"), .product(name: "VaultClassifierCore", package: "classifier")],
            resources: [
                // Whole folder: rule-core.js (the rule contract) with
                // custom-rule-runtime.js (the Mac app's rule engine on it) and
                // event-sandbox.js (the browser's, which the Safari bridge
                // runs in JSC), plus the editor's group rules.
                .copy("Resources")
            ]
        ),
        .target(
            name: "MacBlockerMacControl",
            dependencies: ["MacBlockerCore", "MacBlockerWebUI"],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS]))
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
                "MacBlockerMacControl",
                "MacBlockerWebUI",
                .product(
                    name: "VaultClassifierApp",
                    package: "classifier",
                    condition: .when(platforms: [.macOS])
                ),
                // The hub secret + auth grammar the browser uses (shared with the
                // Native Messaging host), so ConnectionHub verifies against it.
                .product(
                    name: "VaultClassifierBridge",
                    package: "classifier",
                    condition: .when(platforms: [.macOS])
                )
            ]
        ),
        .executableTarget(
            name: "MacBlockerPanel",
            dependencies: ["MacBlockerAppFeature", "MacBlockerCore"],
            resources: [.copy("Resources")]
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
