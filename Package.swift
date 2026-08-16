// swift-tools-version: 5.9
import PackageDescription

// llama.h includes "ggml.h", which lives in the separate Homebrew ggml keg;
// llama.pc only carries llama.cpp's own include dir, so every target that
// (transitively) imports Cllama needs the shared Homebrew include root too.
let cllamaIncludeFlags: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])]
// libggml* live in the ggml keg; llama.pc's -L only covers llama.cpp's own keg.
let cllamaLinkFlags: [LinkerSetting] = [.unsafeFlags(["-L/opt/homebrew/lib"])]

let package = Package(
    name: "VaultClassifier",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VaultClassifierCore", targets: ["VaultClassifierCore"]),
        .executable(name: "VaultClassifierApp", targets: ["VaultClassifierApp"]),
        .executable(name: "VaultLocalHubNativeHost", targets: ["VaultLocalHubNativeHost"]),
        .executable(name: "VaultLLMEngineSmoke", targets: ["VaultLLMEngineSmoke"]),
    ],
    targets: [
        .target(
            name: "VaultClassifierCore",
            resources: [.copy("Resources")]
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
            swiftSettings: cllamaIncludeFlags
        ),
        .executableTarget(
            name: "VaultClassifierApp",
            dependencies: ["VaultClassifierCore", "VaultClassifierLLM"],
            resources: [.copy("WebAssets")],
            swiftSettings: cllamaIncludeFlags,
            linkerSettings: cllamaLinkFlags
        ),
        .executableTarget(
            name: "VaultLocalHubNativeHost",
            dependencies: ["VaultClassifierCore"]
        ),
        // Runs the Phase-0 title benchmark through the real in-process engine.
        .executableTarget(
            name: "VaultLLMEngineSmoke",
            dependencies: ["VaultClassifierCore", "VaultClassifierLLM"],
            swiftSettings: cllamaIncludeFlags,
            linkerSettings: cllamaLinkFlags
        ),
        .testTarget(
            name: "VaultClassifierCoreTests",
            dependencies: ["VaultClassifierCore"]
        ),
        .testTarget(
            name: "VaultClassifierAppTests",
            dependencies: ["VaultClassifierApp", "VaultClassifierCore"],
            swiftSettings: cllamaIncludeFlags,
            linkerSettings: cllamaLinkFlags
        ),
    ]
)
