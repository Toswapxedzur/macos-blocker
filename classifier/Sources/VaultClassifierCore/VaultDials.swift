import Foundation

// The two user-facing controls of the local classifier (owner decision
// 2026-09-23): everything else that used to be a setting is a constant now.
//
//   Speed ↔ Quality  → which Qwen2.5 model tier runs on this Mac.
//   Strict ↔ Broad   → how many tags a video may carry and how sure the model
//                      must be before it keeps an extra one.
//
// Both exist globally; a classifier type may follow the global position or
// hold its own. House rules and each type's tag tree stay as they were.

/// Which model runs. Each tier is one vetted GGUF in `LocalModelCatalog`.
public enum SpeedQualityDial: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Qwen2.5 3B: about half the time of Balanced, noticeably fewer correct tags.
    case fast
    /// Qwen2.5 7B: the measured default (2026-09-22: 68% correct on the 450-video library).
    case balanced
    /// Qwen2.5 14B: a few points better than Balanced at about twice the time.
    case best

    public static let `default`: SpeedQualityDial = .balanced

    public var id: String { rawValue }

    /// The catalog entry this tier runs.
    public var catalogEntry: LocalModelCatalogEntry { LocalModelCatalog.entry(for: self) }

    /// The GGUF file this tier loads from the app's models folder.
    public var ggufFileName: String { catalogEntry.ggufFileName }

    public static func resolve(_ raw: String?) -> SpeedQualityDial? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return SpeedQualityDial(rawValue: raw)
    }

    /// The tier a pre-dial model file name maps to (state written before
    /// 2026-09-23 stored a file name). An exact catalog match wins; otherwise the
    /// parameter count in the name decides; anything else → nil (follow the default).
    public static func nearest(modelFileName: String?) -> SpeedQualityDial? {
        guard let name = modelFileName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if let exact = LocalModelCatalog.curated.first(where: { $0.ggufFileName == name }) { return exact.tier }
        let lowered = name.lowercased()
        if lowered.contains("14b") { return .best }
        if lowered.contains("7b") || lowered.contains("8b") { return .balanced }
        if lowered.contains("1b") || lowered.contains("1.5b") || lowered.contains("2b") || lowered.contains("3b") || lowered.contains("4b") { return .fast }
        return nil
    }
}

/// How many tags, and how sure the model must be to keep an extra one. Measured
/// 2026-09-23 on the 450-video library, Qwen2.5 7B, research on, eval harness
/// (correct = primary label hit · wrong = wrong-tag share of emitted tags ·
/// clean = tagged videos carrying no wrong tag):
///   1  one tag only                          57% · 9% · 91%   (18% of videos left untagged)
///   2  up to three, extra tags at 0.97 sure  64% · 14% · 83%
///   3  up to three, extra tags at 0.90 sure  67% · 16% · 78%  (default)
///   4  up to three, extra tags at 0.85 sure  68% · 18% · 75%
///   5  like 4, and the model must always tag 72% · 23% · 68%  (nothing left untagged)
public enum StrictnessDial: Int, Codable, Sendable, CaseIterable, Identifiable {
    case strictest = 1
    case strict = 2
    case balanced = 3
    case broad = 4
    case broadest = 5

    public static let `default`: StrictnessDial = .balanced

    public var id: Int { rawValue }

    /// Most tags a video may keep.
    public var maximumTags: Int { self == .strictest ? 1 : 3 }

    /// Fewest tags the model must emit (1 = it may never decline).
    public var minimumTags: Int { self == .broadest ? 1 : 0 }

    public var tagBounds: TagBounds { TagBounds(minimum: minimumTags, maximum: maximumTags) }

    /// How sure the model must be before a second or third tag is kept: the odds
    /// that it chose to continue × the odds of that tag name. The first tag is
    /// never subject to it.
    public var extraTagMinimumOdds: Double {
        switch self {
        case .strictest, .balanced: return 0.90
        case .strict: return 0.97
        case .broad, .broadest: return 0.85
        }
    }

    public static func resolve(_ raw: Int?) -> StrictnessDial? {
        guard let raw else { return nil }
        return StrictnessDial(rawValue: raw)
    }

    /// The position nearest a pre-dial (maximum tags, minimum tags, extra-tag odds)
    /// triple, for state written before 2026-09-23. nil when nothing was set.
    public static func nearest(maximumTags: Int?, minimumTags: Int?, extraTagMinimumOdds: Double?) -> StrictnessDial? {
        guard maximumTags != nil || minimumTags != nil || extraTagMinimumOdds != nil else { return nil }
        if let maximumTags, maximumTags <= 1 { return .strictest }
        if let minimumTags, minimumTags >= 1 { return .broadest }
        guard let odds = extraTagMinimumOdds, odds.isFinite else { return .balanced }
        if odds >= 0.935 { return .strict }
        if odds < 0.875 { return .broad }
        return .balanced
    }
}
