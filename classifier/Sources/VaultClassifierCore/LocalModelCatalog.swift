import Foundation

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
    /// The Speed↔Quality position this artifact serves.
    public let tier: SpeedQualityDial

    public init(
        id: String,
        displayName: String,
        family: String,
        paramsB: Double,
        repo: String,
        ggufFileName: String,
        downloadSizeBytes: Int64,
        minimumRAMGB: Int,
        tier: SpeedQualityDial
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.paramsB = paramsB
        self.repo = repo
        self.ggufFileName = ggufFileName
        self.downloadSizeBytes = downloadSizeBytes
        self.minimumRAMGB = minimumRAMGB
        self.tier = tier
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
}

public enum LocalModelCatalog {
    /// One Qwen2.5 Instruct Q4_K_M artifact per Speed↔Quality position (pruned
    /// to these three on 2026-09-23 after measuring the tiers on the 450-video
    /// library). Sizes are Hugging Face metadata of 2026-09-23 and remain
    /// approximate UI guidance; the downloader reports actual bytes.
    public static let curated: [LocalModelCatalogEntry] = [
        .init(
            id: "qwen2.5-3b-instruct-q4-k-m",
            displayName: "Qwen2.5 3B Instruct",
            family: "Qwen",
            paramsB: 3.09,
            repo: "bartowski/Qwen2.5-3B-Instruct-GGUF",
            ggufFileName: "Qwen2.5-3B-Instruct-Q4_K_M.gguf",
            downloadSizeBytes: 1_929_903_264,
            minimumRAMGB: 8,
            tier: .fast
        ),
        .init(
            id: "qwen2.5-7b-instruct-q4-k-m",
            displayName: "Qwen2.5 7B Instruct",
            family: "Qwen",
            paramsB: 7.62,
            repo: "bartowski/Qwen2.5-7B-Instruct-GGUF",
            ggufFileName: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
            downloadSizeBytes: 4_683_074_240,
            // ~4.7 GB Q4 runs comfortably on a 16 GB Mac alongside a browser
            // (verified on an M1 Pro / 16 GB).
            minimumRAMGB: 16,
            tier: .balanced
        ),
        .init(
            id: "qwen2.5-14b-instruct-q4-k-m",
            displayName: "Qwen2.5 14B Instruct",
            family: "Qwen",
            paramsB: 14.77,
            repo: "bartowski/Qwen2.5-14B-Instruct-GGUF",
            ggufFileName: "Qwen2.5-14B-Instruct-Q4_K_M.gguf",
            downloadSizeBytes: 8_988_110_976,
            minimumRAMGB: 24,
            tier: .best
        ),
    ]

    public static func entry(id: String) -> LocalModelCatalogEntry? {
        curated.first { $0.id == id }
    }

    /// The artifact behind a Speed↔Quality position (every position has one).
    public static func entry(for tier: SpeedQualityDial) -> LocalModelCatalogEntry {
        curated.first { $0.tier == tier } ?? curated[0]
    }

    /// Hardware-aware suggestion: the highest tier whose declared RAM floor the
    /// machine clears, else the smallest.
    public static func recommended(systemRAMGB: Int) -> LocalModelCatalogEntry? {
        curated.filter { $0.minimumRAMGB <= systemRAMGB }.max { $0.paramsB < $1.paramsB }
            ?? curated.min { $0.minimumRAMGB < $1.minimumRAMGB }
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
