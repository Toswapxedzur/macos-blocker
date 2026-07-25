import Foundation
import VaultClassifierCore

/// Stores only bounded model identifiers and model-list capability signals
/// returned by an explicit Probe. It never stores a credential, endpoint,
/// request, or response body.
@MainActor
final class ProviderModelCatalogStore {
    private struct Snapshot: Codable {
        let version: Int
        let catalogs: [String: [ProviderModelCatalogEntry]]
    }

    private struct LegacySnapshot: Codable {
        let version: Int
        let catalogs: [String: [String]]
    }

    private static let currentVersion = 2
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load(allowedProfileIDs: Set<String>) -> [String: [ProviderModelCatalogEntry]] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return [:]
        }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           snapshot.version == Self.currentVersion {
            let catalogs = sanitized(snapshot.catalogs, allowedProfileIDs: allowedProfileIDs)
            if catalogs != snapshot.catalogs {
                save(catalogs, allowedProfileIDs: allowedProfileIDs)
            }
            return catalogs
        }
        guard let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data),
              legacy.version == 1 else {
            return [:]
        }
        let migrated = legacy.catalogs.mapValues {
            $0.map { ProviderModelCatalogEntry(identifier: $0) }
        }
        let catalogs = sanitized(migrated, allowedProfileIDs: allowedProfileIDs)
        if !catalogs.isEmpty {
            save(catalogs, allowedProfileIDs: allowedProfileIDs)
        }
        return catalogs
    }

    func save(_ catalogs: [String: [ProviderModelCatalogEntry]], allowedProfileIDs: Set<String>) {
        let snapshot = Snapshot(
            version: Self.currentVersion,
            catalogs: sanitized(catalogs, allowedProfileIDs: allowedProfileIDs)
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A Probe remains usable for this process if the optional cache
            // cannot be persisted locally.
        }
    }

    private func sanitized(
        _ catalogs: [String: [ProviderModelCatalogEntry]],
        allowedProfileIDs: Set<String>
    ) -> [String: [ProviderModelCatalogEntry]] {
        var result = [String: [ProviderModelCatalogEntry]]()
        for (profileID, rawModels) in catalogs where allowedProfileIDs.contains(profileID) {
            var seen = Set<String>()
            let models = rawModels.compactMap { rawModel -> ProviderModelCatalogEntry? in
                let model = rawModel.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty,
                      model.count <= LLMAssistConfiguration.maximumModelIdentifierLength,
                      seen.insert(model).inserted else {
                    return nil
                }
                return .init(
                    identifier: model,
                    supportsTools: rawModel.supportsTools,
                    supportsNativeWebSearch: rawModel.supportsNativeWebSearch
                )
            }
            guard !models.isEmpty else { continue }
            result[profileID] = Array(models.prefix(ProviderModelCatalogProtocol.maximumModels))
                .sorted { $0.identifier < $1.identifier }
        }
        return result
    }
}
