// swift-tools-version: 5.9

import PackageDescription
import Foundation

// Every transitive engine import uses the same headers as classifier/Package.swift.
// Release builds select the pinned source runtime; ordinary development may
// continue to use the shared Homebrew include root.
let brewPrefix: String = {
    if let runtime = ProcessInfo.processInfo.environment["VAULT_LLAMA_PREFIX"], !runtime.isEmpty {
        return runtime
    }
    if let override = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !override.isEmpty {
        return override
    }
    for candidate in ["/opt/homebrew", "/usr/local"] where FileManager.default.fileExists(atPath: candidate + "/include") {
        return candidate
    }
    return "/opt/homebrew"
}()
// Unconditional on purpose: Xcode does not apply a platform-conditioned unsafe
// flag to a package target.
let cllamaIncludeFlags: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(brewPrefix)/include"])]

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
            ],
            swiftSettings: cllamaIncludeFlags
        ),
        .executableTarget(
            name: "MacBlockerPanel",
            dependencies: ["MacBlockerAppFeature", "MacBlockerCore"],
            resources: [.copy("Resources")],
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
