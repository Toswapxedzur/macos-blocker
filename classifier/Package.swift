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

// llama.h includes "ggml.h", which lives in the separate Homebrew ggml keg;
// llama.pc only carries llama.cpp's own include dir, so every target that
// (transitively) imports Cllama needs the shared Homebrew include root too.
let cllamaIncludeFlags: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(brewPrefix)/include"])]
// libggml* live in the ggml keg; llama.pc's -L only covers llama.cpp's own keg.
let cllamaLinkFlags: [LinkerSetting] = [.unsafeFlags(["-L\(brewPrefix)/lib"])]

let package = Package(
    name: "VaultClassifier",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VaultClassifierCore", targets: ["VaultClassifierCore"]),
        // The classifier UI + tagging service as a library: Mac Vault hosts it as
        // an in-app page (owner decision 2026-09-19 — the classifier is a
        // component of Mac Vault, not a separate product).
        .library(name: "VaultClassifierApp", targets: ["VaultClassifierApp"]),
        .library(name: "VaultClassifierBridge", targets: ["VaultClassifierBridge"]),
        // Standalone development window around the same library (headless rigs).
        .executable(name: "VaultLocalHubNativeHost", targets: ["VaultLocalHubNativeHost"]),
        .executable(name: "VaultLLMEngineSmoke", targets: ["VaultLLMEngineSmoke"]),
        .executable(name: "VaultGroundingSmoke", targets: ["VaultGroundingSmoke"]),
        .executable(name: "VaultFullLoopSmoke", targets: ["VaultFullLoopSmoke"]),
        .executable(name: "VaultClassifierEval", targets: ["VaultClassifierEval"]),
    ],
    targets: [
        .target(
            name: "VaultClassifierCore",
            resources: [.copy("Resources")]
        ),
        // Suite-integration boundary: the browser-bridge operation vocabulary +
        // message DTOs and the local-hub HMAC authentication. Kept OUT of
        // VaultClassifierCore so the tagging core carries no networking/auth and
        // can be reasoned about (and tested) independently of the extension/hub.
        // Depends on Core; nothing in Core depends back on it.
        .target(
            name: "VaultClassifierBridge",
            dependencies: ["VaultClassifierCore"]
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
            dependencies: ["VaultClassifierCore", "VaultClassifierBridge", "VaultClassifierResearch", "VaultClassifierLLM"],
            resources: [.copy("WebAssets")],
            swiftSettings: cllamaIncludeFlags
        ),
        .executableTarget(
            name: "VaultLocalHubNativeHost",
            dependencies: ["VaultClassifierCore", "VaultClassifierBridge"]
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
            dependencies: ["VaultClassifierCore", "VaultClassifierBridge", "VaultClassifierResearch"]
        ),
        .testTarget(
            name: "VaultClassifierAppTests",
            dependencies: ["VaultClassifierApp", "VaultClassifierCore", "VaultClassifierBridge", "VaultClassifierResearch", "VaultClassifierLLM"],
            swiftSettings: cllamaIncludeFlags
        ),
    ]
)
