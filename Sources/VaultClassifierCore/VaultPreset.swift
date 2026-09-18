import Foundation

/// A named starting point a person chooses when creating a classifier type, so
/// nobody has to hand-tune the two dozen underlying fields. A preset bundles the
/// type's on-device-model overrides, its grounded-research profile, and a
/// RAM-appropriate model suggestion. Selecting one writes those fields; the detailed form stays
/// available as "Advanced", which reports when a type has drifted from its
/// preset. Presets populate the underlying knobs — they never remove them.
public enum VaultPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Conservative: only block on very high confidence, decline freely, light
    /// research.
    case gentle
    /// The everyday default: block on solid confidence, research declines and
    /// low-confidence guesses.
    case balanced
    /// Aggressive: block on modest confidence, commit rather than decline, more
    /// research budget.
    case strict
    /// Everything on-device: same blocking as Balanced but no network research.
    case localOnly

    public var id: String { rawValue }
    public static let `default`: VaultPreset = .balanced

    public static func resolve(_ raw: String?) -> VaultPreset? {
        guard let raw else { return nil }
        return VaultPreset(rawValue: raw)
    }

    // MARK: - Canonical bundle the preset writes

    /// Per-type on-device-model overrides.
    public var localModelOverrides: LocalModelOverrides {
        switch self {
        case .gentle, .balanced, .localOnly:
            return LocalModelOverrides(allowDecline: true, thumbnailOcrEvidence: true)
        case .strict:
            // Commit to a tag rather than declining, so borderline content is
            // still caught. More aggressive; trades some confidence calibration.
            return LocalModelOverrides(allowDecline: false, thumbnailOcrEvidence: true)
        }
    }

    /// Per-type grounded-research profile. Provider selection stays the user's
    /// choice and the app-wide research consent is still the master gate, so the
    /// preset only sets intent, the urgency floor (5 = declines only, 4 = also
    /// low-confidence videos), and budgets — never a provider.
    public func researchOverrides(base: ResearchSettings = ResearchSettings()) -> ResearchSettings {
        var settings = base
        switch self {
        case .gentle:
            settings.enabled = true
            settings.urgencyFloor = 5
            settings.requestsPerMinute = 6
            settings.dailyTokenLimit = 5_000
            settings.cooldownHours = 24
        case .balanced:
            settings.enabled = true
            settings.urgencyFloor = 4
            settings.requestsPerMinute = 6
            settings.dailyTokenLimit = 10_000
            settings.cooldownHours = 24
        case .strict:
            settings.enabled = true
            settings.urgencyFloor = 4
            settings.requestsPerMinute = 6
            settings.dailyTokenLimit = 20_000
            settings.cooldownHours = 12
        case .localOnly:
            settings.enabled = false
            settings.urgencyFloor = 5
        }
        return settings
    }

    /// A RAM-appropriate model file, but only when it is already downloaded — a
    /// preset must never point a type at a missing model. nil = inherit the
    /// global model choice (the model library still suggests one per RAM tier).
    public func modelFileName(systemRAMGB: Int, availableModelFiles: [String]) -> String? {
        guard let entry = LocalModelCatalog.recommended(systemRAMGB: systemRAMGB),
              availableModelFiles.contains(entry.ggufFileName) else { return nil }
        return entry.ggufFileName
    }

    // MARK: - Drift detection ("modified from <preset>")

    /// True when a type's overrides still match what this preset writes, so the
    /// UI shows "modified from <preset>" only once they diverge. Model file and
    /// research provider selection are user choices and are excluded.
    public func matches(
        localModelOverrides overrides: LocalModelOverrides?,
        researchOverrides research: ResearchSettings?
    ) -> Bool {
        let targetModel = localModelOverrides
        let model = overrides ?? LocalModelOverrides()
        guard (model.allowDecline ?? true) == (targetModel.allowDecline ?? true),
              (model.thumbnailOcrEvidence ?? LocalModelOverrides.defaultThumbnailOcrEvidence)
                == (targetModel.thumbnailOcrEvidence ?? LocalModelOverrides.defaultThumbnailOcrEvidence),
              model.confidenceThresholds == targetModel.confidenceThresholds,
              (model.houseRules ?? "") == (targetModel.houseRules ?? "") else {
            return false
        }
        let targetResearch = researchOverrides()
        let current = research ?? ResearchSettings()
        return current.enabled == targetResearch.enabled
            && current.urgencyFloor == targetResearch.urgencyFloor
            && current.requestsPerMinute == targetResearch.requestsPerMinute
            && current.dailyTokenLimit == targetResearch.dailyTokenLimit
            && current.cooldownHours == targetResearch.cooldownHours
    }

    // MARK: - Presentation keys (localized in the web shell)

    public var displayNameKey: String { "preset.\(rawValue).name" }
    public var descriptionKey: String { "preset.\(rawValue).desc" }
}
