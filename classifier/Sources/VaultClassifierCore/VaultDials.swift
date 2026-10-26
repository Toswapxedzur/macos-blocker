import Foundation

// The two user-facing controls of the local classifier (owner decision
// 2026-09-23): everything else that used to be a setting is a constant now.
//
//   Strict ↔ Broad   → how many tags a video may carry and how sure the model
//                      must be before it keeps an extra one.
//
// Each group owns these controls. Optional min/max tag counts override only
// the corresponding bound; a blank bound follows its Strict↔Broad position.

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
