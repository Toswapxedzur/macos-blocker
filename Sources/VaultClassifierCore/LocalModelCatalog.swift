import Foundation

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

public enum LocalModelCatalogValidationError: Error, Equatable, LocalizedError {
    case invalidRepository
    case invalidGGUFFileName
    case invalidDownloadURL

    public var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "The model repository is invalid."
        case .invalidGGUFFileName:
            return "The model file name is invalid."
        case .invalidDownloadURL:
            return "The model download URL is invalid."
        }
    }
}

/// One vetted llama.cpp-loadable artifact. The catalog contains GGUF files,
/// not multi-file MLX repositories, so a completed download can be handed to
/// `VaultLocalLLMEngine` without conversion or an adapter.
public struct LocalModelCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let family: String
    public let paramsB: Double
    public let repo: String
    public let ggufFileName: String
    public let downloadSizeBytes: Int64
    public let minimumRAMGB: Int

    public init(
        id: String,
        displayName: String,
        family: String,
        paramsB: Double,
        repo: String,
        ggufFileName: String,
        downloadSizeBytes: Int64,
        minimumRAMGB: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.paramsB = paramsB
        self.repo = repo
        self.ggufFileName = ggufFileName
        self.downloadSizeBytes = downloadSizeBytes
        self.minimumRAMGB = minimumRAMGB
    }

    /// The sole permitted remote artifact route. Validation occurs before URL
    /// construction so path separators, encoded traversal, alternate hosts,
    /// and non-HTTPS schemes cannot enter the request boundary.
    public var downloadURL: URL {
        get throws {
            try LocalModelCatalog.validatedDownloadURL(
                repo: repo,
                ggufFileName: ggufFileName
            )
        }
    }

    // Source-compatible aliases retained for the earlier catalog API.
    public var parameterBillions: Double { paramsB }
    public var quantization: String { "Q4_K_M" }
    public var repositoryURL: String { "https://huggingface.co/\(repo)" }
    public var supportsFixedOutput: Bool { true }
    public var supportsPrefixCache: Bool { true }
    public var meetsCapabilityRequirements: Bool { true }
}

public enum LocalModelCatalog {
    /// Curated Q4_K_M artifacts spanning five model families and 1B–7B-class
    /// footprints. Sizes match the repository metadata as of 2026-08-24 and
    /// remain approximate UI guidance; the downloader reports actual bytes.
    public static let curated: [LocalModelCatalogEntry] = [
        .init(
            id: "llama-3.2-1b-instruct-q4-k-m",
            displayName: "Llama 3.2 1B Instruct",
            family: "Llama",
            paramsB: 1.24,
            repo: "bartowski/Llama-3.2-1B-Instruct-GGUF",
            ggufFileName: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            downloadSizeBytes: 807_694_464,
            minimumRAMGB: 8
        ),
        .init(
            id: "qwen2.5-1.5b-instruct-q4-k-m",
            displayName: "Qwen2.5 1.5B Instruct",
            family: "Qwen",
            paramsB: 1.54,
            repo: "bartowski/Qwen2.5-1.5B-Instruct-GGUF",
            ggufFileName: "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
            downloadSizeBytes: 986_048_768,
            minimumRAMGB: 8
        ),
        .init(
            id: "gemma-2-2b-it-q4-k-m",
            displayName: "Gemma 2 2B IT",
            family: "Gemma",
            paramsB: 2.61,
            repo: "bartowski/gemma-2-2b-it-GGUF",
            ggufFileName: "gemma-2-2b-it-Q4_K_M.gguf",
            downloadSizeBytes: 1_708_582_752,
            minimumRAMGB: 12
        ),
        .init(
            id: "qwen2.5-3b-instruct-q4-k-m",
            displayName: "Qwen2.5 3B Instruct",
            family: "Qwen",
            paramsB: 3.09,
            repo: "bartowski/Qwen2.5-3B-Instruct-GGUF",
            ggufFileName: "Qwen2.5-3B-Instruct-Q4_K_M.gguf",
            downloadSizeBytes: 1_929_903_264,
            minimumRAMGB: 16
        ),
        .init(
            id: "llama-3.2-3b-instruct-q4-k-m",
            displayName: "Llama 3.2 3B Instruct",
            family: "Llama",
            paramsB: 3.21,
            repo: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            ggufFileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            downloadSizeBytes: 2_019_377_696,
            minimumRAMGB: 16
        ),
        .init(
            id: "phi-3.5-mini-instruct-q4-k-m",
            displayName: "Phi 3.5 Mini Instruct",
            family: "Phi",
            paramsB: 3.82,
            repo: "bartowski/Phi-3.5-mini-instruct-GGUF",
            ggufFileName: "Phi-3.5-mini-instruct-Q4_K_M.gguf",
            downloadSizeBytes: 2_393_232_672,
            minimumRAMGB: 16
        ),
        .init(
            id: "mistral-7b-instruct-v0.3-q4-k-m",
            displayName: "Mistral 7B Instruct v0.3",
            family: "Mistral",
            paramsB: 7.25,
            repo: "bartowski/Mistral-7B-Instruct-v0.3-GGUF",
            ggufFileName: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
            downloadSizeBytes: 4_372_812_000,
            minimumRAMGB: 24
        ),
        .init(
            id: "qwen2.5-7b-instruct-q4-k-m",
            displayName: "Qwen2.5 7B Instruct",
            family: "Qwen",
            paramsB: 7.62,
            repo: "bartowski/Qwen2.5-7B-Instruct-GGUF",
            ggufFileName: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
            downloadSizeBytes: 4_683_074_240,
            minimumRAMGB: 24
        ),
    ]

    /// Compatibility spelling for call sites that already consume `eligible`.
    public static var eligible: [LocalModelCatalogEntry] { curated }

    public static func entry(id: String) -> LocalModelCatalogEntry? {
        curated.first { $0.id == id }
    }

    /// Hardware-aware default: the most capable model whose declared RAM floor
    /// the machine clears. Ties favor the smaller download.
    public static func recommended(systemRAMGB: Int) -> LocalModelCatalogEntry? {
        curated
            .filter { $0.minimumRAMGB <= systemRAMGB }
            .sorted { lhs, rhs in
                lhs.paramsB == rhs.paramsB
                    ? lhs.downloadSizeBytes < rhs.downloadSizeBytes
                    : lhs.paramsB > rhs.paramsB
            }
            .first
        ?? curated.min { lhs, rhs in
            lhs.minimumRAMGB == rhs.minimumRAMGB
                ? lhs.downloadSizeBytes < rhs.downloadSizeBytes
                : lhs.minimumRAMGB < rhs.minimumRAMGB
        }
    }

    public static func validatedDownloadURL(repo: String, ggufFileName: String) throws -> URL {
        guard isSafeRepository(repo) else {
            throw LocalModelCatalogValidationError.invalidRepository
        }
        guard isSafeGGUFFileName(ggufFileName) else {
            throw LocalModelCatalogValidationError.invalidGGUFFileName
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repo)/resolve/main/\(ggufFileName)"
        guard let url = components.url,
              url.scheme == "https",
              url.host?.lowercased() == "huggingface.co" else {
            throw LocalModelCatalogValidationError.invalidDownloadURL
        }
        return url
    }

    public static func isSafeGGUFFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              fileName.utf8.count <= 255,
              fileName.lowercased().hasSuffix(".gguf"),
              !fileName.contains(".."),
              fileName.unicodeScalars.allSatisfy({ safePathCharacters.contains($0) }) else {
            return false
        }
        return (fileName as NSString).lastPathComponent == fileName
    }

    private static func isSafeRepository(_ repo: String) -> Bool {
        guard repo.utf8.count <= 200 else { return false }
        let components = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." &&
                component.unicodeScalars.allSatisfy { safePathCharacters.contains($0) }
        }
    }

    private static let safePathCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )
}

public enum HardwareProfile {
    /// Physical RAM in whole GB (rounded down), for the recommendation marker.
    public static func physicalRAMGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }
}
