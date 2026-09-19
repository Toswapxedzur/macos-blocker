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

    /// The settings payload sent back for an `activity-settings` get.
    public static func settingsPayload(_ settings: ActivitySettings) -> [String: Any] {
        var byCategory: [String: [String: Any]] = [:]
        for category in ActivityCategory.allCases {
            let value = settings.settings(for: category)
            byCategory[category.rawValue] = ["enabled": value.enabled, "retentionDays": value.retentionDays]
        }
        return ["byCategory": byCategory, "idleThresholdSeconds": settings.idleThresholdSeconds]
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

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}
