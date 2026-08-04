import Foundation

public struct ChromeExtensionImportResult: Sendable {
    public var groups: [BlockGroup]
    public var warnings: [String]

    public init(groups: [BlockGroup], warnings: [String] = []) {
        self.groups = groups
        self.warnings = warnings
    }
}

public enum ChromeExtensionImporter {
    public static func importGroups(from data: Data) throws -> ChromeExtensionImportResult {
        let raw = try JSONSerialization.jsonObject(with: data)
        let sourceGroups: [[String: Any]]
        if let array = raw as? [[String: Any]] {
            sourceGroups = array
        } else if let object = raw as? [String: Any],
                  let array = object["blockedGroups"] as? [[String: Any]] {
            sourceGroups = array
        } else {
            throw ImportError.unsupportedShape
        }

        var warnings: [String] = []
        let groups = sourceGroups.map { object in
            importGroup(object, warnings: &warnings)
        }
        return ChromeExtensionImportResult(groups: groups, warnings: warnings)
    }

    private static func importGroup(_ object: [String: Any], warnings: inout [String]) -> BlockGroup {
        let groupType = BlockGroupType(rawValue: string(object["groupType"]) ?? "site") ?? .site
        let id = string(object["id"]) ?? UUID().uuidString
        let scheduleText = string(object["timeWindowsText"]) ?? ""
        let sites = (object["sites"] as? [Any] ?? [])
            .compactMap { normalizeHost(string($0)) }
            .map {
                BlockTarget(
                    kind: .webDomain,
                    displayName: $0,
                    normalizedValue: $0,
                    tags: legacyTags(for: groupType)
                )
            }

        // Default Block Mode now blocks native applications. Each app entry is
        // { id: <bundleIdentifier>, name: <displayName> } and maps to an
        // application BlockTarget keyed on its bundle id.
        let apps = (object["apps"] as? [[String: Any]] ?? [])
            .compactMap { entry -> BlockTarget? in
                guard let bundleID = string(entry["id"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !bundleID.isEmpty
                else {
                    return nil
                }
                let name = string(entry["name"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return BlockTarget(
                    id: bundleID,
                    kind: .application,
                    displayName: (name?.isEmpty == false ? name! : bundleID),
                    normalizedValue: bundleID,
                    tags: ["mac", "application"]
                )
            }

        var unsupported: [String] = []
        if groupType != .site && groupType != .custom {
            unsupported.append("Platform DOM/feed controls are imported as target metadata only.")
        }
        if bool(object["skipToNextOnBlock"]) == true {
            unsupported.append("skipToNextOnBlock is not available on iOS.")
        }
        if let fallbackURL = string(object["fallbackUrl"]), !fallbackURL.isEmpty {
            unsupported.append("fallbackUrl is replaced by shield/status messaging.")
        }

        warnings.append(contentsOf: unsupported.map { "\(string(object["name"]) ?? id): \($0)" })

        return BlockGroup(
            id: id,
            groupType: mapGroupType(groupType),
            name: string(object["name"]) ?? defaultName(for: groupType),
            enabled: bool(object["enabled"]) ?? true,
            mode: BlockingMode(rawValue: string(object["mode"]) ?? "") ?? .instant,
            allowedMinutes: int(object["allowedMinutes"]) ?? 15,
            resetIntervalHours: int(object["resetIntervalHours"]) ?? 24,
            allowSnooze: bool(object["allowSnooze"]) ?? true,
            snoozeMinutes: int(object["snoozeMinutes"]) ?? 30,
            snoozeActivationDelayMinutes: int(object["snoozeActivationDelayMinutes"]) ?? 0,
            snoozeCooldownMinutes: int(object["snoozeCooldownMinutes"]) ?? 0,
            snoozeConfirmations: int(object["snoozeConfirmations"]) ?? 0,
            activeDays: parseDays(object["activeDays"]),
            timeWindows: ScheduleParser.parseWindows(scheduleText),
            freezeMode: mapFreezeMode(string(object["freezeMode"])),
            strictFreezeHours: int(object["strictFreezeHours"]) ?? 24,
            frozenAt: dateFromMilliseconds(object["frozenAtMs"]),
            parentalPasswordHash: string(object["parentalPasswordHash"]),
            parentalPasswordSalt: string(object["parentalPasswordSalt"]),
            fallbackMessage: "",
            customRuleSource: string(object["blockingRulesText"]) ?? "",
            targets: sites + apps,
            unsupportedLegacyFeatures: unsupported
        )
    }

    /// Maps the JS `freezeMode` strings to the Swift enum. The web layer uses
    /// `"frozen"` for the normal freeze; the Swift enum spells that `.normal`.
    private static func mapFreezeMode(_ raw: String?) -> FreezeMode {
        switch raw {
        case "frozen", "normal": return .normal
        case "strict": return .strict
        case "parental": return .parental
        default: return .none
        }
    }

    /// The macOS app blocks whole apps/sites only; the extension's platform
    /// group types collapse to the generic `.app` type natively.
    private static func mapGroupType(_ groupType: BlockGroupType) -> BlockGroupType {
        switch groupType {
        case .youtube, .tiktok, .facebook, .instagram, .twitch, .reddit, .discord, .twitter:
            return .app
        default:
            return groupType
        }
    }

    private static func legacyTags(for groupType: BlockGroupType) -> Set<String> {
        switch groupType {
        case .youtube, .tiktok, .facebook, .instagram:
            return ["social", "shortVideo", groupType.rawValue]
        case .twitch:
            return ["video", "streaming", groupType.rawValue]
        case .reddit, .discord, .twitter:
            return ["social", groupType.rawValue]
        default:
            return []
        }
    }

    private static func parseDays(_ value: Any?) -> Set<Weekday> {
        guard let values = value as? [Any] else {
            return Set(Weekday.allCases)
        }
        let days = values.compactMap { Weekday(rawValue: string($0) ?? "") }
        return days.isEmpty ? Set(Weekday.allCases) : Set(days)
    }

    /// Normalizes a user-typed site/URL to a bare host (scheme- and `www.`-
    /// stripped, lowercased) for enforcement and for `GroupStore` dedupe. Kept
    /// module-internal so there is one normalization, not a drifting copy.
    static func normalizeHost(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else {
            return nil
        }
        if !value.contains("://") {
            value = "https://" + value
        }
        guard let host = URL(string: value)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func defaultName(for groupType: BlockGroupType) -> String {
        groupType == .custom ? "Custom Block" : "Block Group"
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func bool(_ value: Any?) -> Bool? {
        value as? Bool
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func dateFromMilliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }
}

public enum ImportError: Error, Equatable {
    case unsupportedShape
}
