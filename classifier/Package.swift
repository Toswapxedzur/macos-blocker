// swift-tools-version: 5.9
import PackageDescription
import Foundation

#if os(Windows)
let portableDependencies: [Package.Dependency] = [.package(url: "https://github.com/apple/swift-crypto.git", exact: "4.3.1")]
let cryptoDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto"), "CVaultWindows"]
let appExcludes = ["VaultClassifierWebShell.swift", "VaultClassifierPage.swift"]
let coreTestExcludes = ["NativeMessagingHostRegistrationTests.swift"]
let nativeHostProducts: [Product] = []
let nativeHostTargets: [Target] = []
let windowsTargets: [Target] = [.target(name: "CVaultWindows", linkerSettings: [
    .linkedLibrary("crypt32"), .linkedLibrary("bcrypt"), .linkedLibrary("advapi32"),
    .linkedLibrary("ole32"), .linkedLibrary("windowscodecs"), .linkedLibrary("shlwapi"), .linkedLibrary("uuid"), .linkedLibrary("shell32"),
])]
#else
let portableDependencies: [Package.Dependency] = []
let cryptoDependencies: [Target.Dependency] = []
let appExcludes: [String] = []
let coreTestExcludes: [String] = []
let nativeHostProducts: [Product] = [.executable(name: "VaultLocalHubNativeHost", targets: ["VaultLocalHubNativeHost"])]
let nativeHostTargets: [Target] = [.executableTarget(name: "VaultLocalHubNativeHost", dependencies: ["VaultClassifierCore", "VaultClassifierBridge"])]
let windowsTargets: [Target] = []
#endif

let bridgeDependencies: [Target.Dependency] = [.target(name: "VaultClassifierCore")] + cryptoDependencies
let appDependencies: [Target.Dependency] = [.target(name: "VaultClassifierCore"), .target(name: "VaultClassifierBridge"), .target(name: "VaultClassifierResearch"), .target(name: "VaultActivityCore")] + cryptoDependencies
let coreTestDependencies: [Target.Dependency] = [.target(name: "VaultClassifierCore"), .target(name: "VaultClassifierBridge"), .target(name: "VaultClassifierResearch")] + cryptoDependencies
let package = Package(
    name: "VaultClassifier",
    platforms: [.macOS("13.3")],
    products: nativeHostProducts + [
        .library(name: "VaultClassifierCore", targets: ["VaultClassifierCore"]),
        .library(name: "VaultActivityCore", targets: ["VaultActivityCore"]),
        .library(name: "VaultClassifierApp", targets: ["VaultClassifierApp"]),
        .library(name: "VaultClassifierBridge", targets: ["VaultClassifierBridge"]),
        .executable(name: "VaultClassifierWorker", targets: ["VaultClassifierWorker"]),
    ],
    dependencies: portableDependencies,
    targets: windowsTargets + nativeHostTargets + [
        .target(name: "CVaultOAuth", linkerSettings: [.linkedLibrary("ws2_32", .when(platforms: [.windows]))]),
        .target(name: "VaultActivityCore", dependencies: ["VaultClassifierCore"]),
        .target(name: "VaultClassifierCore", dependencies: cryptoDependencies, resources: [.copy("Resources")]),
        .target(name: "VaultClassifierBridge", dependencies: bridgeDependencies),
        .target(name: "VaultClassifierResearch", dependencies: [.target(name: "VaultClassifierCore"), .target(name: "CVaultOAuth")] + cryptoDependencies),
        .target(name: "VaultClassifierApp", dependencies: appDependencies, exclude: appExcludes, resources: [.copy("WebAssets")]),
        .executableTarget(name: "VaultClassifierWorker", dependencies: ["VaultClassifierApp"]),
        .testTarget(name: "VaultClassifierCoreTests", dependencies: coreTestDependencies, exclude: coreTestExcludes),
        .testTarget(name: "VaultClassifierAppTests", dependencies: ["VaultClassifierApp", "VaultClassifierCore", "VaultClassifierBridge", "VaultClassifierResearch"])
    ]
)
