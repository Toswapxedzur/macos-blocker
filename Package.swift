// swift-tools-version: 5.9

import PackageDescription
import Foundation

// The classifier component links Homebrew's llama.cpp. llama.h includes
// "ggml.h" from the separate ggml keg, so every target that (transitively)
// imports the engine needs the shared Homebrew include root — the same rule,
// and the same prefix resolution, as classifier/Package.swift.
let brewPrefix: String = {
    if let override = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !override.isEmpty {
        return override
    }
    for candidate in ["/opt/homebrew", "/usr/local"] where FileManager.default.fileExists(atPath: candidate + "/include") {
        return candidate
    }
    return "/opt/homebrew"
}()
// Unconditional on purpose: Xcode does not apply a platform-conditioned unsafe
// flag to a package target, and the extra search path is inert on iOS.
let cllamaIncludeFlags: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(brewPrefix)/include"])]

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
    dependencies: [
        // The Vault Classifier component (on-device tagging + its page). It lives
        // in this repository under classifier/ and is macOS-only.
        .package(path: "classifier")
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
            ],
            swiftSettings: cllamaIncludeFlags
        ),
        .executableTarget(
            name: "MacBlockerPanel",
            dependencies: ["MacBlockerAppFeature"],
            swiftSettings: cllamaIncludeFlags
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
            dependencies: ["MacBlockerAppFeature"],
            swiftSettings: cllamaIncludeFlags
        )
    ]
)
