// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Homebrew prefix, resolved at manifest-eval time so the package builds on
// Apple Silicon (/opt/homebrew), Intel (/usr/local), or a custom install
// (HOMEBREW_PREFIX) — never a hardcoded path.
let brewPrefix: String = {
    if let override = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !override.isEmpty {
        return override
    }
    for candidate in ["/opt/homebrew", "/usr/local"] where FileManager.default.fileExists(atPath: candidate + "/include") {
        return candidate
    }
    return "/opt/homebrew"
}()

// The Windows package links a pinned llama.cpp build installed by the worker
// bundler; macOS continues to use the existing Homebrew integration.
#if os(Windows)
let nativePrefix = ProcessInfo.processInfo.environment["VAULT_LLAMA_PREFIX"] ?? "C:/vault-porting-classifier/llama-runtime"
let portableDependencies: [Package.Dependency] = [.package(url: "https://github.com/apple/swift-crypto.git", exact: "4.3.1")]
let cryptoDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto"), "CVaultWindows"]
let appExcludes = ["VaultClassifierWebShell.swift", "VaultClassifierPage.swift"]
let coreTestExcludes = ["NativeMessagingHostRegistrationTests.swift"]
let nativeHostProducts: [Product] = []
let nativeHostTargets: [Target] = []
let windowsTargets: [Target] = [.target(name: "CVaultWindows", linkerSettings: [
    .linkedLibrary("crypt32"), .linkedLibrary("bcrypt"), .linkedLibrary("advapi32"),
    .linkedLibrary("ole32"), .linkedLibrary("windowscodecs"), .linkedLibrary("shlwapi"), .linkedLibrary("uuid"),
])]
#else
let nativePrefix = brewPrefix
let portableDependencies: [Package.Dependency] = []
let cryptoDependencies: [Target.Dependency] = []
let appExcludes: [String] = []
let coreTestExcludes: [String] = []
let nativeHostProducts: [Product] = [.executable(name: "VaultLocalHubNativeHost", targets: ["VaultLocalHubNativeHost"])]
let nativeHostTargets: [Target] = [.executableTarget(name: "VaultLocalHubNativeHost", dependencies: ["VaultClassifierCore", "VaultClassifierBridge"])]
let windowsTargets: [Target] = []
#endif
let cllamaIncludeFlags: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(nativePrefix)/include"])]
let cllamaLinkFlags: [LinkerSetting] = [.unsafeFlags(["-L\(nativePrefix)/lib"])]

let bridgeDependencies: [Target.Dependency] = [.target(name: "VaultClassifierCore")] + cryptoDependencies
let appDependencies: [Target.Dependency] = [.target(name: "VaultClassifierCore"), .target(name: "VaultClassifierBridge"), .target(name: "VaultClassifierResearch"), .target(name: "VaultClassifierLLM"), .target(name: "VaultActivityCore")] + cryptoDependencies
let coreTestDependencies: [Target.Dependency] = [.target(name: "VaultClassifierCore"), .target(name: "VaultClassifierBridge"), .target(name: "VaultClassifierResearch")] + cryptoDependencies

let classifierProducts: [Product] = nativeHostProducts + [
        .library(name: "VaultClassifierCore", targets: ["VaultClassifierCore"]),
        .library(name: "VaultActivityCore", targets: ["VaultActivityCore"]),
        .executable(name: "VaultClassifierWorker", targets: ["VaultClassifierWorker"]),
        // The classifier UI + tagging service as a library: Mac Vault hosts it as
        // an in-app page (owner decision 2026-09-19 — the classifier is a
        // component of Mac Vault, not a separate product).
        .library(name: "VaultClassifierApp", targets: ["VaultClassifierApp"]),
        .library(name: "VaultClassifierBridge", targets: ["VaultClassifierBridge"]),
        // Standalone development window around the same library (headless rigs).
        .executable(name: "VaultLLMEngineSmoke", targets: ["VaultLLMEngineSmoke"]),
        .executable(name: "VaultGroundingSmoke", targets: ["VaultGroundingSmoke"]),
        .executable(name: "VaultFullLoopSmoke", targets: ["VaultFullLoopSmoke"]),
        .executable(name: "VaultClassifierEval", targets: ["VaultClassifierEval"]),
    ]

let classifierTargets: [Target] = windowsTargets + nativeHostTargets + [
        .target(name: "VaultActivityCore", dependencies: ["VaultClassifierCore"]),
        .target(
            name: "VaultClassifierCore",
            dependencies: cryptoDependencies,
            resources: [.copy("Resources")]
        ),
        // Suite-integration boundary: the browser-bridge operation vocabulary +
        // message DTOs and the local-hub HMAC authentication. Kept OUT of
        // VaultClassifierCore so the tagging core carries no networking/auth and
        // can be reasoned about (and tested) independently of the extension/hub.
        // Depends on Core; nothing in Core depends back on it.
        .target(
            name: "VaultClassifierBridge",
            dependencies: bridgeDependencies
        ),
        // Cloud grounded-research EXECUTION (provider request plans, HTTP seam,
        // generation/test/catalog protocols, the research executor). Optional
        // enrichment kept out of Core so on-device tagging builds and runs with
        // no network-facing code; Core keeps only the persisted research/provider
        // DATA and the queue actor, which takes the executor as a closure.
        .target(
            name: "VaultClassifierResearch",
            dependencies: ["VaultClassifierCore"]
        ),
        // Homebrew's llama.cpp (libllama + Metal-at-runtime ggml). Resolved via
        // pkg-config, so `brew install llama.cpp` is the only prerequisite.
        .systemLibrary(
            name: "Cllama",
            pkgConfig: "llama",
            providers: [.brew(["llama.cpp"])]
        ),
        // The in-process on-device LLM engine (final Phase-0 contract). Kept in
        // its own library so both the app and the smoke benchmark can link it
        // while VaultClassifierCore stays free of native dependencies.
        .target(
            name: "VaultClassifierLLM",
            dependencies: ["VaultClassifierCore", "Cllama"],
            swiftSettings: cllamaIncludeFlags,
            // Carried by the library so every product that links the engine —
            // including Mac Vault, the classifier's host — finds the ggml keg.
            linkerSettings: cllamaLinkFlags
        ),
        .target(
            name: "VaultClassifierApp",
            dependencies: appDependencies,
            exclude: appExcludes,
            resources: [.copy("WebAssets")],
            swiftSettings: cllamaIncludeFlags
        ),
        .executableTarget(
            name: "VaultClassifierWorker",
            dependencies: ["VaultClassifierApp", "VaultClassifierCore"],
            swiftSettings: cllamaIncludeFlags
        ),
        // Live smoke test for provider-native search grounding (one real call).
        .executableTarget(
            name: "VaultGroundingSmoke",
            dependencies: ["VaultClassifierCore", "VaultClassifierResearch"]
        ),
        // End-to-end loop: real engine + real Gemini grounding + coordinator.
        .executableTarget(
            name: "VaultFullLoopSmoke",
            dependencies: ["VaultClassifierCore", "VaultClassifierResearch", "VaultClassifierLLM"],
            swiftSettings: cllamaIncludeFlags
        ),
        // Classification accuracy eval harness (sample → label → score).
        .executableTarget(
            name: "VaultClassifierEval",
            dependencies: ["VaultClassifierCore", "VaultClassifierLLM"],
            swiftSettings: cllamaIncludeFlags
        ),
        // Runs the Phase-0 title benchmark through the real in-process engine.
        .executableTarget(
            name: "VaultLLMEngineSmoke",
            dependencies: ["VaultClassifierCore", "VaultClassifierLLM"],
            swiftSettings: cllamaIncludeFlags
        ),
        .testTarget(
            name: "VaultClassifierCoreTests",
            dependencies: coreTestDependencies,
            exclude: coreTestExcludes
        ),
        .testTarget(
            name: "VaultClassifierAppTests",
            dependencies: ["VaultClassifierApp", "VaultClassifierCore", "VaultClassifierBridge", "VaultClassifierResearch", "VaultClassifierLLM"],
            swiftSettings: cllamaIncludeFlags
        ),
    ]

let package = Package(
    name: "VaultClassifier",
    platforms: [.macOS(.v13)],
    products: classifierProducts,
    dependencies: portableDependencies,
    targets: classifierTargets
)
