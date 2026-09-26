import Foundation

/// File-backed store inside the App Group container: where Mac Vault keeps the
/// editor's store (web-store.json) and its other small files.
public final class SharedAppGroupStore: @unchecked Sendable {
    public static let webStoreFileName = "web-store.json"

    public let baseDirectory: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "macosBlocker.SharedAppGroupStore")

    public init(baseDirectory: URL = AppGroup.baseDirectory()) {
        self.baseDirectory = baseDirectory
        print("[SharedAppGroupStore] init baseDirectory: \(baseDirectory.path)")
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
                try data.write(to: target, options: [.atomic])
            } catch {
                print("[SharedAppGroupStore] writeData FAILED for \(target.path): \(error)")
            }
        }
    }

    public func removeFile(_ fileName: String) {
        queue.sync { try? fileManager.removeItem(at: url(for: fileName)) }
    }

    // MARK: Codable convenience

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func readJSON<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        guard let data = readData(fileName) else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    public func writeJSON<T: Encodable>(_ value: T, to fileName: String) {
        guard let data = try? Self.encoder.encode(value) else { return }
        writeData(data, to: fileName)
    }
}
