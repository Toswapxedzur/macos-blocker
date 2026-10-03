import Foundation
import MacBlockerCore

/// Reads only the interface preference and bundled strings; policy data is untouched.
public enum VaultNativeLanguage {
    private static let cacheLock = NSLock()
    private static var lastPreferenceBytes: Data?
    private static var lastLanguage: String?
    private static var catalogs: [String: [String: String]] = [:]
    public static var language: String {
        let bytes = SharedAppGroupStore().readData(SharedAppGroupStore.webStoreFileName, silent: true)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if bytes == lastPreferenceBytes, let language = lastLanguage { return language }
        let object = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let preferred = object?["vaultUiLanguage"] as? String ?? Locale.preferredLanguages.first ?? "en"
        let code = preferred.lowercased().split(separator: "-").first.map(String.init) ?? "en"
        let language = ["en", "ar", "bn", "de", "es", "fr", "hi", "id", "it", "ja", "ko", "nl", "pa", "pl", "pt", "ru", "th", "tr", "vi", "zh"].contains(code) ? code : "en"
        lastPreferenceBytes = bytes
        lastLanguage = language
        return language
    }
    public static func text(_ key: String, fallback: String, values: [String: String] = [:]) -> String {
        var result = fallback
        if let root = WebAssetsLocator.assetsDirectory {
            let url = root.appendingPathComponent("translation/\(language).json")
            cacheLock.lock()
            let identity = url.path
            if catalogs[identity] == nil,
               let data = try? Data(contentsOf: url),
               let catalog = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
                catalogs[identity] = catalog
            }
            result = catalogs[identity]?[key] ?? fallback
            cacheLock.unlock()
        }
        for (name, value) in values { result = result.replacingOccurrences(of: "{\(name)}", with: value) }
        return result
    }
}
