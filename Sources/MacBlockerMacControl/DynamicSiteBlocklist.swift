#if os(macOS)
import Foundation

/// A runtime-managed blocklist of website patterns. Custom rules can add/remove
/// entries via `getWindowHelper().block("youtube.com")`. The enforcement bridge
/// checks this list each tick and closes matching browser tabs.
public final class DynamicSiteBlocklist: @unchecked Sendable {
    private var patterns: Set<String> = []
    private let lock = NSLock()

    public init() {}

    public func add(_ pattern: String) {
        let normalized = Self.normalize(pattern)
        guard !normalized.isEmpty else { return }
        lock.lock()
        patterns.insert(normalized)
        lock.unlock()
    }

    public func remove(_ pattern: String) {
        let normalized = Self.normalize(pattern)
        lock.lock()
        patterns.remove(normalized)
        lock.unlock()
    }

    public func isBlocked(_ urlOrHostname: String) -> Bool {
        let hostname = Self.extractHostname(urlOrHostname)
        guard !hostname.isEmpty else { return false }
        lock.lock()
        let blocked = patterns.contains(where: { pattern in
            hostname == pattern || hostname.hasSuffix("." + pattern)
        })
        lock.unlock()
        return blocked
    }

    public func allPatterns() -> [String] {
        lock.lock()
        let result = Array(patterns).sorted()
        lock.unlock()
        return result
    }

    public func clear() {
        lock.lock()
        patterns.removeAll()
        lock.unlock()
    }

    // MARK: - Normalization

    private static func normalize(_ pattern: String) -> String {
        var p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if p.hasPrefix("http://") { p = String(p.dropFirst(7)) }
        if p.hasPrefix("https://") { p = String(p.dropFirst(8)) }
        if p.hasPrefix("www.") { p = String(p.dropFirst(4)) }
        if let slashIdx = p.firstIndex(of: "/") { p = String(p[..<slashIdx]) }
        return p
    }

    private static func extractHostname(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.hasPrefix("http://") || v.hasPrefix("https://") {
            if let url = URL(string: v), let host = url.host {
                v = host
            } else {
                if v.hasPrefix("http://") { v = String(v.dropFirst(7)) }
                else { v = String(v.dropFirst(8)) }
                if let slashIdx = v.firstIndex(of: "/") { v = String(v[..<slashIdx]) }
            }
        }
        if v.hasPrefix("www.") { v = String(v.dropFirst(4)) }
        return v
    }
}
#endif
