#if os(macOS)
import Foundation
import CryptoKit
import VaultClassifierCore
import MacBlockerWebUI

/// Named transcripts are local to the device and shared across all rules.
public actor RuleAIConversations {
    static var defaultRoot: URL {
        BlockerWebStore().fileURL.deletingLastPathComponent().appendingPathComponent("rule-ai-conversations", isDirectory: true)
    }
    private static let ioLock = NSRecursiveLock()
    nonisolated(unsafe) private static var lastTimestamp: Int64 = 0
    nonisolated private static func nextTimestamp() -> Int64 {
        lastTimestamp = max(lastTimestamp + 1, Int64(Date().timeIntervalSince1970 * 1000))
        return lastTimestamp
    }
    struct Message: Codable, Equatable {
        var id: String
        var role: String
        var text: String
        var model: String
        var at: Int64
    }
    struct Document: Codable, Equatable {
        var version: Int = 1
        var name: String
        var messages: [Message]
        var preservedNames: [String]? = nil
        var lastUsedAt: Int64? = nil
    }
    private let root: URL
    init(root: URL) { self.root = root }
    struct Prepared {
        var history: String
        var preservedNames: [String]
    }

    nonisolated private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private func url(_ member: String, _ name: String) -> URL {
        root.appendingPathComponent(digest(name) + ".json")
    }
    nonisolated private func read(_ member: String, _ name: String) throws -> Document? {
        let file = url(member, name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
        guard document.version == 1, document.name == name else { throw RuleAIError.conversationStorage }
        return document
    }
    nonisolated private func write(_ document: Document, members: [String]) throws {
        let data = try JSONEncoder().encode(document)
        let file = url("", document.name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    nonisolated private func isPrefix(_ left: [Message], of right: [Message]) -> Bool {
        left.count <= right.count && zip(left, right).allSatisfy { $0 == $1 }
    }
    nonisolated private func separateName(_ name: String, member: String, members: [String]) throws -> String {
        let base = String(name.prefix(88)) + "~" + String(digest(member).prefix(10))
        var candidate = base, suffix = 2
        while try members.contains(where: { try read($0, candidate) != nil }) {
            candidate = base + "-" + String(suffix); suffix += 1
        }
        return candidate
    }
    nonisolated private func reconcile(_ members: [String], _ name: String) throws -> (Document, [String]) {
        try migrate()
        let document = try read("", name) ?? Document(name: name, messages: [])
        return (document, document.preservedNames ?? [])
    }
    nonisolated private func limitMB() throws -> Int {
        let target = root.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: target.path) else { return 1024 }
        let value = try JSONDecoder().decode(Int.self, from: Data(contentsOf: target))
        guard value > 0 && value <= 1_000_000 else { throw RuleAIError.conversationStorage }
        return value
    }
    nonisolated private func trim(protecting name: String? = nil) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let limit = Int64(try limitMB()) * 1_048_576
        var entries: [(URL, Date, Int64)] = []
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" && file.lastPathComponent != "settings.json" {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            entries.append((file, attributes[.modificationDate] as? Date ?? .distantPast,
                            (attributes[.size] as? NSNumber)?.int64Value ?? 0))
        }
        var used = entries.reduce(Int64(0)) { $0 + $1.2 }
        if let name, let current = entries.first(where: { $0.0 == url("", name) }), current.2 > limit { throw RuleAIError.conversationStorage }
        for entry in entries.sorted(by: { ($0.1, $0.0.path) < ($1.1, $1.0.path) }) where used > limit {
            if let name, entry.0 == url("", name) { continue }
            try FileManager.default.removeItem(at: entry.0)
            used -= entry.2
        }
        if used > limit { throw RuleAIError.conversationStorage }
    }
    // Import transcripts written by the earlier private per-member build.
    nonisolated private func migrate() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if folders.isEmpty { return }
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            for old in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                where old.pathExtension == "json" {
                let oldDoc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: old))
                guard oldDoc.version == 1, old.lastPathComponent == digest(oldDoc.name) + ".json" else { throw RuleAIError.conversationStorage }
                var imported = oldDoc
                if let primary = try read("", oldDoc.name), primary.messages != oldDoc.messages {
                    if isPrefix(primary.messages, of: oldDoc.messages) {
                        imported.preservedNames = primary.preservedNames
                        try write(imported, members: [])
                    } else if !isPrefix(oldDoc.messages, of: primary.messages) {
                        let base = String(oldDoc.name.prefix(88)) + "~" + String(folder.lastPathComponent.prefix(10))
                        var candidate = base, suffix = 2
                        while try read("", candidate) != nil { candidate = base + "-" + String(suffix); suffix += 1 }
                        imported.name = candidate
                        var updated = primary
                        updated.preservedNames = Array(Set((updated.preservedNames ?? []) + [candidate])).sorted()
                        try write(updated, members: [])
                    }
                }
                if try read("", imported.name) == nil { try write(imported, members: []) }
                try FileManager.default.removeItem(at: old)
            }
            if (try FileManager.default.contentsOfDirectory(atPath: folder.path)).isEmpty {
                try FileManager.default.removeItem(at: folder)
            }
        }
        try trim()
    }
    private func recentText(_ messages: [Message]) -> String {
        var pieces: [String] = [], bytes = 0
        for message in messages.reversed() {
            let piece = (message.role == "assistant" ? "Assistant: " : "User: ") + message.text + "\n"
            let size = piece.utf8.count
            if bytes + size > 16_000 {
                if pieces.isEmpty {
                    var tail = ""
                    for character in piece.reversed() {
                        let next = String(character) + tail
                        if next.utf8.count > 16_000 { break }
                        tail = next
                    }
                    pieces.append(tail)
                }
                break
            }
            pieces.append(piece); bytes += size
        }
        return pieces.reversed().joined()
    }
    func prepare(members: [String], name: String) throws -> Prepared {
        Self.ioLock.lock(); defer { Self.ioLock.unlock() }
        do {
            var (document, preservedNames) = try reconcile(members, name)
            document.lastUsedAt = Self.nextTimestamp()
            if !document.messages.isEmpty { try write(document, members: []) }
            return Prepared(history: recentText(document.messages), preservedNames: preservedNames)
        }
        catch { throw RuleAIError.conversationStorage }
    }
    func append(members: [String], name: String, model: String, user: String, assistant: String) throws {
        Self.ioLock.lock(); defer { Self.ioLock.unlock() }
        do {
            var document = try reconcile(members, name).0
            let now = Self.nextTimestamp()
            document.messages.append(Message(id: UUID().uuidString, role: "user", text: user, model: model, at: now))
            document.messages.append(Message(id: UUID().uuidString, role: "assistant", text: assistant, model: model, at: now))
            document.lastUsedAt = now
            guard Int64(try JSONEncoder().encode(document).count) <= Int64(try limitMB()) * 1_048_576 else { throw RuleAIError.conversationStorage }
            try write(document, members: members)
            try trim(protecting: name)
        } catch { throw RuleAIError.conversationStorage }
    }
    func delete(name: String) throws {
        Self.ioLock.lock(); defer { Self.ioLock.unlock() }
        do {
            try migrate()
            let target = url("", name)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        } catch { throw RuleAIError.conversationStorage }
    }
    func setting(action: String, mb: Int? = nil) throws -> Int {
        Self.ioLock.lock(); defer { Self.ioLock.unlock() }
        do {
            try migrate()
            if action == "set" {
                guard let mb, mb > 0 && mb <= 1_000_000 else { throw RuleAIError.conversationStorage }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONEncoder().encode(mb).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
                try trim()
            }
            return try limitMB()
        } catch { throw RuleAIError.conversationStorage }
    }
    nonisolated public static func settingSync(action: String, mb: Int?) throws -> Int {
        ioLock.lock(); defer { ioLock.unlock() }
        let store = RuleAIConversations(root: defaultRoot)
        try store.migrate()
        if action == "set" {
            guard let mb, mb > 0 && mb <= 1_000_000 else { throw RuleAIError.conversationStorage }
            try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(mb).write(to: defaultRoot.appendingPathComponent("settings.json"), options: .atomic)
            try store.trim()
        }
        return try store.limitMB()
    }
    nonisolated static func copyAllBeforeUnlink(members: [String], root: URL = defaultRoot) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        try RuleAIConversations(root: root).migrate()
    }
}
#endif
