import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One-way alpha migration. Preserve retired data before the active schema drops
/// its keys. No dormant record is decoded into a prompt, UI, service or queue.
enum DormantKnowledgeArchive {
    static func preserve(from data: Data, beside stateFile: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["schemaVersion"] as? Int ?? 0) < 8 else { return }
        let settings = root["settings"] as? [String: Any] ?? [:]
        let catalog = root["workspaceCatalog"] as? [String: Any] ?? [:]
        let oldSettings = settings.filter { ["research", "dictionaries"].contains($0.key) }
        let oldCatalog = catalog.filter { ["knowledgeEntries", "creatorKnowledge", "researchAttempts", "creatorResearchAccumulators"].contains($0.key) }
        let groups = (catalog["classifierTypes"] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
            let fields = group.filter { ["id", "researchEnabled", "researchOverrides"].contains($0.key) }
            return fields.count > 1 ? fields : nil
        }
        guard !oldSettings.isEmpty || !oldCatalog.isEmpty || !groups.isEmpty else { return }
        let payload: [String: Any] = ["format": "vault.dormant-knowledge", "schemaVersion": 1,
            "sourceSchemaVersion": root["schemaVersion"] ?? 0, "settings": oldSettings,
            "workspaceCatalog": oldCatalog, "classifierGroups": groups]
        let archived = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let digest = SHA256.hash(data: archived).map { String(format: "%02x", $0) }.joined()
        let directory = stateFile.deletingLastPathComponent().appendingPathComponent("dormant", isDirectory: true)
        try VaultPrivateFile.createDirectory(at: directory)
        let destination = directory.appendingPathComponent("knowledge-\(digest).json")
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == archived else { throw CocoaError(.fileWriteFileExists) }
        } else {
            try archived.write(to: destination, options: .atomic)
        }
        try VaultPrivateFile.restrict(destination)
    }
}
