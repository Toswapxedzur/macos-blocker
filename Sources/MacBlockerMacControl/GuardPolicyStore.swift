import Foundation
import MacBlockerCore

#if os(macOS)
import Darwin
#endif

/// Persists the `GuardPolicy` to disk so the always-on enforcement core can
/// read it independently of the editor app's lifetime.
///
/// When running as root (the system extension / privileged daemon) the
/// canonical location is `/Library/Application Support/Blocker/policy.json`,
/// which a non-admin user cannot edit — they can't unblock by hand-editing the
/// file. When running unprivileged (e.g. the editor during development) it
/// falls back to the per-user Application Support directory.
public struct GuardPolicyStore: Sendable {
    public enum StoreError: Error, Equatable {
        case encodingFailed
        case writeFailed(String)
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init() {
        self.url = Self.defaultURL()
    }

    public static var directoryName: String {
        VaultRuntimeEnvironment.current.policyDirectoryName
    }
    public static let fileName = "policy.json"

    /// Root → system-wide root-owned path; otherwise the per-user path.
    public static func defaultURL() -> URL {
        #if os(macOS)
        if geteuid() == 0 {
            return URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(fileName)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func load() -> GuardPolicy? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder().decode(GuardPolicy.self, from: data)
    }

    public func save(_ policy: GuardPolicy) throws {
        guard let data = try? Self.encoder().encode(policy) else {
            throw StoreError.encodingFailed
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }
}
