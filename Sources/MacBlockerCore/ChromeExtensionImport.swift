import Foundation

public struct ChromeExtensionImportResult: Sendable {
    public var groups: [BlockGroup]

    public init(groups: [BlockGroup]) {
        self.groups = groups
    }
}

public enum ChromeExtensionImporter {
    public static func importGroups(from data: Data) throws -> ChromeExtensionImportResult {
        try importGroups(fromObject: try JSONSerialization.jsonObject(with: data))
    }

    /// A store document (`{blockedGroups: […]}`) or a bare group array, parsed.
    public static func importGroups(fromObject raw: Any) throws -> ChromeExtensionImportResult {
        let sourceGroups: [[String: Any]]
        if let array = raw as? [[String: Any]] {
            sourceGroups = array
        } else if let object = raw as? [String: Any],
                  let array = object["blockedGroups"] as? [[String: Any]] {
            sourceGroups = array
        } else {
            throw ImportError.unsupportedShape
        }

        // Read exactly as the editor stores them: through its own sanitizer
        // (group-scopes.js sanitizeGroups), so a field is never read differently.
        let sanitized = GroupActionsRuntime.shared.call("sanitizeGroups", [sourceGroups], module: "CBGroupScopes") as? [[String: Any]] ?? sourceGroups
        return ChromeExtensionImportResult(groups: sanitized.map(importGroup))
    }

    /// Mac Vault controls apps only (the scope line): a group's Apps line is
    /// all it reads; website and platform lines are a browser's.
    private static func importGroup(_ object: [String: Any]) -> BlockGroup {
        let apps = WebStoreDocument.apps(of: object).compactMap { entry -> BlockTarget? in
            guard let bundleID = string(entry["id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty else { return nil }
            let name = string(entry["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return BlockTarget(
                id: bundleID,
                kind: .application,
                displayName: (name?.isEmpty == false ? name! : bundleID),
                normalizedValue: bundleID,
                tags: ["mac", "application"]
            )
        }
        return BlockGroup(
            id: string(object["id"]) ?? UUID().uuidString,
            groupType: string(object["groupType"]) == "custom" ? .custom : .site,
            name: string(object["name"]) ?? "Block Group",
            enabled: bool(object["enabled"]) ?? false,
            mode: BlockingMode.reconcile(string(object["mode"])),
            allowedMinutes: positive(object["allowedMinutes"]) ?? 15,
            resetIntervalHours: positive(object["resetIntervalHours"]) ?? 24,
            resetAtMidnight: bool(object["resetAtMidnight"]) ?? false,
            rollingLimit: bool(object["rollingLimit"]) ?? false,
            activeDays: parseDays(object["activeDays"]),
            timeWindows: ScheduleParser.parseWindows(string(object["timeWindowsText"]) ?? ""),
            // What Run last loaded (the editor's text runs only once Run).
            customRuleSource: string(object["activeEventSource"]) ?? "",
            targets: apps,
            applicationAllowlist: WebStoreDocument.appsExcept(of: object)
        )
    }

    private static func parseDays(_ value: Any?) -> Set<Weekday> {
        guard let values = value as? [Any] else {
            return Set(Weekday.allCases)
        }
        // A stored empty list means "no day" (never active), as in the extension;
        // only a missing list defaults to every day.
        return Set(values.compactMap { Weekday(rawValue: string($0) ?? "") })
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func bool(_ value: Any?) -> Bool? {
        value as? Bool
    }

    /// Keeps fractions (a 2.5 h interval must not truncate to 2, nor 0.5 h to 0).
    private static func positive(_ value: Any?) -> Double? {
        double(value).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        return nil
    }
}

public enum ImportError: Error, Equatable {
    case unsupportedShape
}
