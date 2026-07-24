import Foundation
import VaultClassifierCore

/// Stores only the bounded model identifiers returned by an explicit Probe.
/// It never stores a provider credential, endpoint, request, or response body.
@MainActor
final class ProviderModelCatalogStore {
    private struct Snapshot: Codable {
        let version: Int
        let catalogs: [String: [String]]
    }

    private static let currentVersion = 1
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load(allowedProfileIDs: Set<String>) -> [String: [String]] {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == Self.currentVersion else {
            return [:]
        }
        let catalogs = sanitized(snapshot.catalogs, allowedProfileIDs: allowedProfileIDs)
        if catalogs != snapshot.catalogs {
            save(catalogs, allowedProfileIDs: allowedProfileIDs)
        }
        return catalogs
    }

    func save(_ catalogs: [String: [String]], allowedProfileIDs: Set<String>) {
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

    private func sanitized(_ catalogs: [String: [String]], allowedProfileIDs: Set<String>) -> [String: [String]] {
        var result = [String: [String]]()
        for (profileID, rawModels) in catalogs where allowedProfileIDs.contains(profileID) {
            var seen = Set<String>()
            let models = rawModels.compactMap { rawModel -> String? in
                let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty,
                      model.count <= LLMAssistConfiguration.maximumModelIdentifierLength,
                      seen.insert(model).inserted else {
                    return nil
                }
                return model
            }
            guard !models.isEmpty else { continue }
            result[profileID] = Array(models.prefix(ProviderModelCatalogProtocol.maximumModels)).sorted()
        }
        return result
    }
}
