import Foundation

// Curated catalog of user-selectable on-device models (see REWORK §7.5). The
// model is NOT fixed: the user picks from vetted entries, downloaded on demand.
// Entries carry required capability flags (fixed/structured output + prefix-cache
// friendliness); models lacking them are ineligible. The actual download +
// MLX loading is the runtime layer (Phase 0); this is its data + selection logic.

/// The user's latency budget bands for one classification decision.
public enum LatencyBand: String, Codable, Sendable, CaseIterable {
    case green   // < 500 ms — fine
    case danger  // 500 ms – 1 s — dangerous
    case reject  // > 1 s — unacceptable

    public static func classify(medianMilliseconds: Double) -> LatencyBand {
        if medianMilliseconds < 500 { return .green }
        if medianMilliseconds <= 1_000 { return .danger }
        return .reject
    }
}

public struct LocalModelCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    /// Model repo id, e.g. "mlx-community/Llama-3.2-3B-Instruct-4bit".
    public let id: String
    public let displayName: String
    public let parameterBillions: Double
    public let quantization: String
    public let downloadSizeBytes: Int64
    public let minimumRAMGB: Int
    public let repositoryURL: String
    /// Reliably follows a constrained/structured output schema.
    public let supportsFixedOutput: Bool
    /// Works with prompt-prefix KV-cache reuse.
    public let supportsPrefixCache: Bool

    public init(
        id: String, displayName: String, parameterBillions: Double, quantization: String,
        downloadSizeBytes: Int64, minimumRAMGB: Int, repositoryURL: String,
        supportsFixedOutput: Bool, supportsPrefixCache: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.parameterBillions = parameterBillions
        self.quantization = quantization
        self.downloadSizeBytes = downloadSizeBytes
        self.minimumRAMGB = minimumRAMGB
        self.repositoryURL = repositoryURL
        self.supportsFixedOutput = supportsFixedOutput
        self.supportsPrefixCache = supportsPrefixCache
    }

    /// Both capability gates must pass for a model to be offered (REWORK §7.5).
    public var meetsCapabilityRequirements: Bool { supportsFixedOutput && supportsPrefixCache }
}

public enum LocalModelCatalog {
    /// Vetted models spanning weak → powerful hardware. All are MLX-Swift-loadable
    /// Apple-Silicon 4-bit builds that support structured output + prefix caching.
    /// Sizes are approximate; the downloader records the real size.
    public static let curated: [LocalModelCatalogEntry] = [
        .init(id: "mlx-community/Llama-3.2-1B-Instruct-4bit", displayName: "Llama 3.2 1B (4-bit)",
              parameterBillions: 1.24, quantization: "4bit", downloadSizeBytes: 700_000_000,
              minimumRAMGB: 8, repositoryURL: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit",
              supportsFixedOutput: true, supportsPrefixCache: true),
        .init(id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", displayName: "Qwen2.5 1.5B (4-bit)",
              parameterBillions: 1.54, quantization: "4bit", downloadSizeBytes: 900_000_000,
              minimumRAMGB: 8, repositoryURL: "https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit",
              supportsFixedOutput: true, supportsPrefixCache: true),
        .init(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B (4-bit)",
              parameterBillions: 3.21, quantization: "4bit", downloadSizeBytes: 1_800_000_000,
              minimumRAMGB: 16, repositoryURL: "https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit",
              supportsFixedOutput: true, supportsPrefixCache: true),
        .init(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", displayName: "Qwen2.5 3B (4-bit)",
              parameterBillions: 3.09, quantization: "4bit", downloadSizeBytes: 1_800_000_000,
              minimumRAMGB: 16, repositoryURL: "https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit",
              supportsFixedOutput: true, supportsPrefixCache: true),
        .init(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", displayName: "Qwen2.5 7B (4-bit)",
              parameterBillions: 7.6, quantization: "4bit", downloadSizeBytes: 4_300_000_000,
              minimumRAMGB: 24, repositoryURL: "https://huggingface.co/mlx-community/Qwen2.5-7B-Instruct-4bit",
              supportsFixedOutput: true, supportsPrefixCache: true),
    ]

    /// Only models that pass the capability gates are offered.
    public static var eligible: [LocalModelCatalogEntry] {
        curated.filter(\.meetsCapabilityRequirements)
    }

    public static func entry(id: String) -> LocalModelCatalogEntry? {
        curated.first { $0.id == id }
    }

    /// Hardware-aware default: the most capable eligible model whose RAM floor
    /// the machine clears. Ties on size break toward the smaller download.
    public static func recommended(systemRAMGB: Int) -> LocalModelCatalogEntry? {
        eligible
            .filter { $0.minimumRAMGB <= systemRAMGB }
            .sorted { lhs, rhs in
                lhs.parameterBillions == rhs.parameterBillions
                    ? lhs.downloadSizeBytes < rhs.downloadSizeBytes
                    : lhs.parameterBillions > rhs.parameterBillions
            }
            .first
        // If nothing clears the RAM floor, fall back to the smallest eligible model.
        ?? eligible.min { $0.minimumRAMGB < $1.minimumRAMGB }
    }
}

public enum HardwareProfile {
    /// Physical RAM in whole GB (rounded down), for the recommended default.
    public static func physicalRAMGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }
}
