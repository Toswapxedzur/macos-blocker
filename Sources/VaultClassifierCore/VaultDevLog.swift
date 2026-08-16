import Foundation

// Development-only unified log sink for the whole blockerGroup pipeline.
//
// The pill lifecycle spans three processes (extension content script → service
// worker → native app), each with its own console. This writes structured,
// timestamped lines from ALL of them into ONE file so a single video can be
// traced end-to-end: `grep 'entry=youtube:video:XYZ' dev.log`.
//
// Active ONLY when `ADAMANCIA_VAULT_ENVIRONMENT == "development"`. The file path
// comes from `ADAMANCIA_VAULT_DEV_LOG` (the dev launch points it at
// blockerGroup/misc/dev.log); if unset it falls back to the dev support dir.
// Never active in production. Lines may contain titles/creator ids — dev only.
public final class VaultDevLog: @unchecked Sendable {
    public static let shared = VaultDevLog()

    private let queue = DispatchQueue(label: "com.adamancia.vault.devlog")
    private let enabled: Bool
    private let fileURL: URL?
    private let maximumBytes = 5 * 1024 * 1024
    private let formatter: ISO8601DateFormatter

    private init() {
        let env = ProcessInfo.processInfo.environment
        let isDev = env["ADAMANCIA_VAULT_ENVIRONMENT"] == "development"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter = iso
        guard isDev else {
            enabled = false
            fileURL = nil
            return
        }
        if let path = env["ADAMANCIA_VAULT_DEV_LOG"], !path.isEmpty {
            fileURL = URL(fileURLWithPath: path)
        } else {
            fileURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("VaultClassifier-Development/dev.log")
        }
        enabled = fileURL != nil
    }

    public var isEnabled: Bool { enabled }

    /// Append one structured line: `<iso8601-ms> [layer] event k=v k=v`.
    /// Fields are sorted for stable, diffable output.
    public func log(_ layer: String, _ event: String, _ fields: [String: String] = [:]) {
        guard enabled, let fileURL else { return }
        let stamp = formatter.string(from: Date())
        let rendered = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.sanitize($0.value))" }
            .joined(separator: " ")
        let line = rendered.isEmpty
            ? "\(stamp) [\(layer)] \(event)\n"
            : "\(stamp) [\(layer)] \(event) \(rendered)\n"
        queue.async { self.append(line, to: fileURL) }
    }

    private func append(_ line: String, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maximumBytes {
            let backup = url.appendingPathExtension("1")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: url, to: backup)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}
