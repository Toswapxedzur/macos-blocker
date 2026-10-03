import Foundation
import MacBlockerCore

/// Reads only the interface preference and bundled strings; policy data is untouched.
public enum VaultNativeLanguage {
    public static var language: String {
        let bytes = SharedAppGroupStore().readData(SharedAppGroupStore.webStoreFileName, silent: true)
        let object = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let preferred = object?["vaultUiLanguage"] as? String ?? Locale.preferredLanguages.first ?? "en"
        let code = preferred.lowercased().split(separator: "-").first.map(String.init) ?? "en"
        return ["en", "ar", "bn", "de", "es", "fr", "hi", "id", "it", "ja", "ko", "nl", "pa", "pl", "pt", "ru", "th", "tr", "vi", "zh"].contains(code) ? code : "en"
    }
    public static func text(_ key: String, fallback: String, values: [String: String] = [:]) -> String {
        var result = fallback
        if let root = WebAssetsLocator.assetsDirectory,
           let data = try? Data(contentsOf: root.appendingPathComponent("translation/\(language).json")),
           let catalog = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            result = catalog[key] ?? fallback
        }
        for (name, value) in values { result = result.replacingOccurrences(of: "{\(name)}", with: value) }
        return result
    }
}
