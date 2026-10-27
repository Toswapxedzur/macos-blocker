import Foundation
#if canImport(Darwin)
import Darwin
#endif
import VaultClassifierCore

/// Reservations contain only group identities, never prompts, results or keys.
/// A linked reservation belongs to every member. Union on link deduplicates it;
/// each detached member retains its previous usage without resetting the cap.
public final class RuleAIUsage {
    private struct Ledger: Codable { var version = 1; var day: Int; var reservations: [[String]] }
    private static let lock = NSLock()
    private let url: URL
    public init(url: URL) { self.url = url }
    public func reserve(members: [String], limit: Int?, now: Date = Date()) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw RuleAIError.storage }
        #if canImport(Darwin)
        let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RuleAIError.storage }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw RuleAIError.storage }
        defer { flock(descriptor, LOCK_UN) }
        #endif
        let members = Array(Set(members)).sorted()
        guard !members.isEmpty, members.count <= 16, members.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }), limit == nil || (1...100_000).contains(limit!) else { throw RuleAIError.invalidConfiguration }
        let day = Int(now.timeIntervalSince1970 / 86400)
        var ledger = Ledger(day: day, reservations: [])
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard data.count <= 8_000_000 else { throw RuleAIError.storage }
                ledger = try JSONDecoder().decode(Ledger.self, from: data)
                guard ledger.version == 1 else { throw RuleAIError.storage }
                if ledger.day != day { ledger = Ledger(day: day, reservations: []) }
            }
            let scope = Set(members)
            let used = ledger.reservations.filter { !scope.isDisjoint(with: $0) }.count
            if let limit, used >= limit { throw RuleAIError.usageLimit }
            guard ledger.reservations.count < 100_000 else { throw RuleAIError.storage }
            ledger.reservations.append(members)
            let data = try JSONEncoder().encode(ledger)
            guard data.count <= 8_000_000 else { throw RuleAIError.storage }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as RuleAIError { throw error }
        catch { throw RuleAIError.storage }
    }
}
