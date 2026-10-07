import Foundation
import VaultClassifierCore

/// File-backed store inside the App Group container: where Mac Vault keeps the
/// editor's store (web-store.json) and its other small files.
public final class SharedAppGroupStore: @unchecked Sendable {
    public static let webStoreFileName = "web-store.json"
    public static let webSchema = StorageSchemaPolicy(format: "vault.web-store", currentSchema: 3)

    public let baseDirectory: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "macosBlocker.SharedAppGroupStore")

    public init(baseDirectory: URL = AppGroup.baseDirectory()) {
        self.baseDirectory = baseDirectory
    }

    public func url(for fileName: String) -> URL {
        baseDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func ensureDirectory() {
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            print("[SharedAppGroupStore] ensureDirectory FAILED for \(baseDirectory.path): \(error)")
        }
    }

    // MARK: Raw bytes

    public func readData(_ fileName: String, silent: Bool = false) -> Data? {
        queue.sync {
            let target = url(for: fileName)
            // A read interrupted by a signal (EINTR, seen at launch while the
            // process is still starting up) is transient: retry briefly rather
            // than report "no store", which made the editor fall back to its
            // stale local copy and write that back over the file.
            var attempt = 0
            while true {
                do {
                    return try Data(contentsOf: target)
                } catch {
                    let posixCode = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code
                    if posixCode == Int(EINTR), attempt < 5 {
                        attempt += 1
                        usleep(20_000)
                        continue
                    }
                    if !silent {
                        print("[SharedAppGroupStore] readData FAILED for \(target.path): \(error)")
                    }
                    return nil
                }
            }
        }
    }

    public func writeData(_ data: Data, to fileName: String) {
        queue.sync {
            ensureDirectory()
            let target = url(for: fileName)
            do {
                var output = data
                if fileName == Self.webStoreFileName {
                    if fileManager.fileExists(atPath: target.path) {
                        guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any] else { throw StorageSchemaError.unsupported("invalid web store") }
                        try Self.webSchema.validateFlat(existing)
                    }
                    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StorageSchemaError.unsupported("invalid web store") }
                    output = try JSONSerialization.data(withJSONObject: Self.webSchema.stampFlat(root), options: [.sortedKeys])
                }
                try output.write(to: target, options: [.atomic])
            } catch {
                print("[SharedAppGroupStore] writeData FAILED for \(target.path): \(error)")
            }
        }
    }

}
