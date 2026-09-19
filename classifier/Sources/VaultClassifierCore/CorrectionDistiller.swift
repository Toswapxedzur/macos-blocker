import Foundation

/// A legacy "Learned preferences" block may still sit inside a classifier type's
/// stored house rules: an on-device LLM used to write free-text rules there and
/// fabricated some ("tag Samsung videos as Sports"), so that feature was removed
/// (5ca3ff7) and corrections now reach the model only as per-video retrieved
/// exemplars. This type exists solely to strip that block, so a stale one can
/// never re-enter a prompt. Re-measured 2026-09-18 on synthetic corrections: a 7B
/// fabricates too whenever evidence is thin, and no summarised-rule variant beat
/// plain live corrections — so nothing here writes rules any more.
public enum CorrectionDistiller {
    public static let startMarker = "[Learned preferences"
    public static let endMarker = "[/Learned preferences]"

    /// The user's own house rules with any legacy learned block removed.
    public static func manualRules(from houseRules: String?) -> String {
        let value = houseRules ?? ""
        guard let start = value.range(of: startMarker) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var retained = String(value[..<start.lowerBound])
        if let end = value.range(of: endMarker, range: start.lowerBound..<value.endIndex) {
            retained += String(value[end.upperBound...])
        }
        return retained.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func containsLearnedPreferences(_ houseRules: String?) -> Bool {
        houseRules?.contains(startMarker) == true && houseRules?.contains(endMarker) == true
    }
}
