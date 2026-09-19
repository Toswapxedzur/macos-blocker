import Foundation
import VaultClassifierCore

/// A small, local-only trace for the browser collection pipeline. It persists
/// no browsing content: every record is made of fixed protocol checkpoints and
/// an optional fixed failure code. Keeping it outside `LocalClassifierState`
/// means it can be cleared independently without touching datasets or models.
@MainActor
final class CollectionDiagnosticsStore {
    struct Record: Codable, Equatable {
        static let maximumRetainedRecords = 200

        let id: UUID
        let recordedAtMilliseconds: Int64
        let platformID: String?
        let event: String
        let detail: String?
        let outcome: String
    }

    private let fileURL: URL
    private(set) var records: [Record] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func record(
        platformID: String? = nil,
        event: String,
        detail: String? = nil,
        outcome: String = "received"
    ) {
        let sanitizedPlatform = sanitizePlatformID(platformID)
        let sanitizedEvent = sanitizeToken(event, maximumLength: 64) ?? "invalid-event"
        let sanitizedDetail = sanitizeToken(detail, maximumLength: 64)
        let sanitizedOutcome = sanitizeToken(outcome, maximumLength: 32) ?? "unknown"
        records.append(.init(
            id: UUID(),
            recordedAtMilliseconds: Self.now(),
            platformID: sanitizedPlatform,
            event: sanitizedEvent,
            detail: sanitizedDetail,
            outcome: sanitizedOutcome
        ))
        if records.count > Record.maximumRetainedRecords {
            records.removeFirst(records.count - Record.maximumRetainedRecords)
        }
        save()
    }

    func clear() {
        records = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Record].self, from: data) else {
            return
        }
        records = Array(stored.suffix(Record.maximumRetainedRecords)).filter { record in
            sanitizeToken(record.event, maximumLength: 64) != nil &&
            sanitizeToken(record.outcome, maximumLength: 32) != nil &&
            (record.platformID == nil || sanitizePlatformID(record.platformID) != nil) &&
            (record.detail == nil || sanitizeToken(record.detail, maximumLength: 64) != nil)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Diagnostics are observational. A local write failure must not
            // disrupt collection or replace the authoritative dataset state.
        }
    }

    private static func now() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private func sanitizePlatformID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 0x61 && scalar.value <= 0x7a) ||
                  (scalar.value >= 0x30 && scalar.value <= 0x39) ||
                  scalar.value == 0x2d
              }) else {
            return nil
        }
        return value
    }

    private func sanitizeToken(_ value: String?, maximumLength: Int) -> String? {
        guard let value, !value.isEmpty, value.count <= maximumLength,
              value.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 0x61 && scalar.value <= 0x7a) ||
                  (scalar.value >= 0x30 && scalar.value <= 0x39) ||
                  scalar.value == 0x2d
              }) else {
            return nil
        }
        return value
    }
}
