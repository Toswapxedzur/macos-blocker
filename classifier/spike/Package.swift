// swift-tools-version: 5.9
import PackageDescription

// ISOLATED latency-spike package (REWORK Phase 0). Kept OUT of the main
// VaultClassifier package on purpose: pulling MLX (Metal kernels) is a heavy
// build, and isolating it means a slow or failing MLX compile can never red the
// main project. Run from this directory:
//     swift run -c release spike mlx-community/Llama-3.2-1B-Instruct-4bit
//     swift run -c release spike mlx-community/Llama-3.2-3B-Instruct-4bit
// First run downloads the model from Hugging Face.
let package = Package(
    name: "spike",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pin to a tagged release: `main` is mid-refactor and (as of this writing)
        // stops exposing MLXLLM/MLXLMCommon as products. 2.29.1 exposes them.
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.29.1"),
    ],
    targets: [
        .executableTarget(
            name: "spike",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
    ]
)
