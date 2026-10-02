#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import VaultClassifierCore

/// The pictures of creators in Knowledge, kept as long as their knowledge
/// (owner 2026-09-30) — the source-icon cache keeps only its newest 512. One
/// small JPEG per creator, named by a one-way hash of the creator id, served
/// to the page through the source-icon scheme under host "creator".
final class CreatorPictureStore {
    static let host = "creator"
    private let directory: URL

    init?(directory: URL?) {
        guard let directory else { return nil }
        self.directory = directory
        do {
            try VaultPrivateFile.createDirectory(at: directory, fileManager: FileManager.default)
        } catch {
            return nil
        }
    }

    /// The page's URL for a kept picture, or nil when there is none yet.
    func url(for creatorID: String) -> String? {
        let key = Self.key(creatorID)
        guard FileManager.default.fileExists(atPath: fileURL(key).path) else { return nil }
        return "\(SourceIconCache.scheme)://\(Self.host)/\(key)"
    }

    func save(_ jpeg: Data, for creatorID: String) {
        try? jpeg.write(to: fileURL(Self.key(creatorID)), options: .atomic)
    }

    func remove(creatorID: String) {
        try? FileManager.default.removeItem(at: fileURL(Self.key(creatorID)))
    }

    func response(for requestURL: URL) -> Data? {
        guard requestURL.host == Self.host,
              let key = requestURL.pathComponents.last,
              key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let data = try? Data(contentsOf: fileURL(key)), !data.isEmpty else { return nil }
        return data
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).jpg", isDirectory: false)
    }

    private static func key(_ creatorID: String) -> String {
        SHA256.hash(data: Data(creatorID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
