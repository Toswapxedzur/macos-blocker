import Foundation

/// Translates between the hub's JSON activity messages (from the extension) and
/// the typed store, and merges settings updates. Pure and Foundation-only so it
/// is unit tested without the networking hub (see ACTIVITY-LOG.md §5).
///
/// The wire record format is deliberately independent of the on-disk `Codable`:
/// the extension sends `startedAtMs` (epoch milliseconds) rather than a date
/// string, and the browser may only write browser categories — a wire record
/// claiming `appUsage` is dropped, so the extension can never forge native
/// app-usage time.
public enum ActivityWire {
    public static let maxRecordsPerFlush = 500

    /// Categories the extension is allowed to write.
    public static let browserCategories: Set<ActivityCategory> = [.webVisit, .contentWatched]

    /// Parses and validates the records in an `activity-record` body
    /// (`{"records": [ ... ]}`). Invalid or non-browser records are dropped.
    public static func records(from body: [String: Any]) -> [ActivityRecord] {
        guard let raw = body["records"] as? [[String: Any]] else { return [] }
        var out: [ActivityRecord] = []
        for entry in raw.prefix(maxRecordsPerFlush) {
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let categoryRaw = entry["category"] as? String,
                  let category = ActivityCategory(rawValue: categoryRaw),
                  browserCategories.contains(category),
                  let seconds = number(entry["seconds"]), seconds > 0,
                  let key = entry["key"] as? String, !key.isEmpty,
                  let label = entry["label"] as? String else { continue }
            let startedAt: Date
            if let ms = number(entry["startedAtMs"]) {
                startedAt = Date(timeIntervalSince1970: ms / 1000)
            } else {
                startedAt = Date()
            }
            out.append(ActivityRecord(
                id: id,
                category: category,
                startedAt: startedAt,
                seconds: seconds,
                key: key,
                label: label,
                platform: entry["platform"] as? String,
                creator: entry["creator"] as? String
            ))
        }
        return out
    }

    /// Strict browser metadata is consumed by admission, never persisted. The
    /// legacy pure record parser remains separate from this authenticated path.
    public static func browserRecords(from body: [String: Any]) -> [ActivityBrowserRecord] {
        guard let raw = body["records"] as? [[String: Any]] else { return [] }
        return raw.prefix(maxRecordsPerFlush).compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty, id.count <= 256,
                  let rawCategory = entry["category"] as? String,
                  let category = ActivityCategory(rawValue: rawCategory), browserCategories.contains(category),
                  let start = browserNumber(entry["startedAtMs"]), start.isFinite, start >= 0,
                  let seconds = browserNumber(entry["seconds"]), seconds.isFinite, seconds > 0,
                  let key = entry["key"] as? String, !key.isEmpty,
                  let label = entry["label"] as? String else { return nil }
            var authorization: ActivityRecordAuthorization?
            if let value = entry["authorization"] as? [String: Any],
               let epoch = value["epoch"] as? String, UUID(uuidString: epoch) != nil,
               let n = value["revision"] as? NSNumber, !["c", "B"].contains(String(cString: n.objCType)),
               n.doubleValue.isFinite, n.doubleValue >= 0,
               n.doubleValue <= Double(ActivitySettingsSnapshot.maxRevision),
               n.doubleValue.rounded(.towardZero) == n.doubleValue {
                authorization = .init(epoch: epoch, revision: n.intValue)
            }
            return ActivityBrowserRecord(record: ActivityRecord(id: id, category: category,
                startedAt: Date(timeIntervalSince1970: start / 1_000), seconds: seconds,
                key: key, label: label, platform: entry["platform"] as? String, creator: entry["creator"] as? String),
                authorization: authorization, observedEndedAtMs: browserNumber(entry["observedEndedAtMs"]))
        }
    }

    public static func browserRecordIDs(from body: [String: Any]) -> [String] {
        guard let raw = body["records"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return raw.prefix(maxRecordsPerFlush).compactMap {
            guard let id = $0["id"] as? String, !id.isEmpty, id.count <= 256, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// Refuse all rows for IDs repeated within a submitted batch, including an
    /// invalid row paired with a valid one. Later-batch replay is independent.
    public static func duplicateBrowserRecordIDs(from body: [String: Any]) -> Set<String> {
        guard let raw = body["records"] as? [[String: Any]] else { return [] }
        var seen = Set<String>(), duplicate = Set<String>()
        for entry in raw.prefix(maxRecordsPerFlush) {
            guard let id = entry["id"] as? String, !id.isEmpty, id.count <= 256 else { continue }
            if !seen.insert(id).inserted { duplicate.insert(id) }
        }
        return duplicate
    }

    /// The settings payload sent back for an `activity-settings` get.
    public static func settingsPayload(_ settings: ActivitySettings) -> [String: Any] {
        var byCategory: [String: [String: Any]] = [:]
        for category in ActivityCategory.allCases {
            let value = settings.settings(for: category)
            var entry: [String: Any] = ["enabled": value.enabled]
            if let days = value.retentionDays { entry["retentionDays"] = days } // absent = follows the global Keep
            byCategory[category.rawValue] = entry
        }
        return ["byCategory": byCategory, "idleThresholdSeconds": settings.idleThresholdSeconds]
    }

    /// Native-authoritative ordering metadata is ephemeral, never part of the
    /// settings file or accepted from a browser settings update.
    public static func settingsSnapshotPayload(_ snapshot: ActivitySettingsSnapshot) -> [String: Any] {
        ["settings": settingsPayload(snapshot.settings), "epoch": snapshot.epoch,
         "revision": snapshot.revision, "changedAtMs": snapshot.changedAtMs]
    }

    /// Merges an `activity-settings` set body into the current settings. Only the
    /// categories and fields the caller includes are changed, so the extension
    /// (which shows only browser categories) never clobbers the native
    /// `appUsage` toggle.
    public static func merged(_ current: ActivitySettings, with body: [String: Any]) -> ActivitySettings {
        var next = current
        if let byCategory = body["byCategory"] as? [String: [String: Any]] {
            for (categoryRaw, entry) in byCategory {
                guard let category = ActivityCategory(rawValue: categoryRaw) else { continue }
                let existing = next.settings(for: category)
                let enabled = entry["enabled"] as? Bool ?? existing.enabled
                let retention = (entry["retentionDays"] as? NSNumber)?.intValue ?? existing.retentionDays
                next.set(ActivityCategorySettings(enabled: enabled, retentionDays: retention), for: category)
            }
        }
        if let idle = (body["idleThresholdSeconds"] as? NSNumber)?.intValue {
            next.idleThresholdSeconds = idle
        }
        return next
    }

    private static func browserNumber(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, !["c", "B"].contains(String(cString: n.objCType)) else { return nil }
        return n.doubleValue
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}
