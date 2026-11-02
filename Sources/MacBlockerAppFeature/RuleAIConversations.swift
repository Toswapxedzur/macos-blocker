#if os(macOS)
import Foundation
import CryptoKit
import VaultClassifierCore
import MacBlockerWebUI

/// Local transcripts are copied to each member of a linked group. That makes
/// unlink retain the shared history without keeping the former members linked.
actor RuleAIConversations {
    static var defaultRoot: URL {
        BlockerWebStore().fileURL.deletingLastPathComponent().appendingPathComponent("rule-ai-conversations", isDirectory: true)
    }
    private static let ioLock = NSRecursiveLock()
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
        root.appendingPathComponent(digest(member), isDirectory: true)
            .appendingPathComponent(digest(name) + ".json")
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
        for member in members {
            let file = url(member, document.name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
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
        let found = try members.compactMap { member -> (String, Document)? in
            guard let document = try read(member, name) else { return nil }
            return (member, document)
        }
        guard !found.isEmpty else { return (Document(name: name, messages: []), []) }
        // A partial previous copy has a common prefix and is repaired by the
        // longest document. Independent pre-link histories keep distinct names.
        let longest = found.max { $0.1.messages.count < $1.1.messages.count }!.1
        var primary = longest
        var preservedNames = primary.preservedNames ?? []
        for (member, document) in found where !isPrefix(document.messages, of: longest.messages) {
            let newName = try separateName(name, member: member, members: members)
            try write(Document(name: newName, messages: document.messages), members: members)
            preservedNames.append(newName)
        }
        primary.name = name
        primary.preservedNames = preservedNames
        try write(primary, members: members)
        return (primary, preservedNames)
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
            let (document, preservedNames) = try reconcile(members, name)
            return Prepared(history: recentText(document.messages), preservedNames: preservedNames)
        }
        catch { throw RuleAIError.conversationStorage }
    }
    func append(members: [String], name: String, model: String, user: String, assistant: String) throws {
        Self.ioLock.lock(); defer { Self.ioLock.unlock() }
        do {
            var document = try reconcile(members, name).0
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            document.messages.append(Message(id: UUID().uuidString, role: "user", text: user, model: model, at: now))
            document.messages.append(Message(id: UUID().uuidString, role: "assistant", text: assistant, model: model, at: now))
            try write(document, members: members)
        } catch { throw RuleAIError.conversationStorage }
    }
    nonisolated static func copyAllBeforeUnlink(members: [String], root: URL = defaultRoot) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        let store = RuleAIConversations(root: root)
        var names = Set<String>()
        for member in members {
            let folder = root.appendingPathComponent(store.digest(member), isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
                guard document.version == 1, file.lastPathComponent == store.digest(document.name) + ".json" else { throw RuleAIError.conversationStorage }
                names.insert(document.name)
            }
        }
        for name in names.sorted() { _ = try store.reconcile(members, name) }
    }
}
#endif
