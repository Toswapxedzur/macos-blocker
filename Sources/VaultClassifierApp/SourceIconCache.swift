import CryptoKit
import Foundation
import WebKit

/// A bounded on-device cache for already-verified source icons. The collection
/// record retains the public URL; this cache holds only a fetched image
/// response keyed by a one-way hash, never post media, a thumbnail, or an
/// arbitrary page image. WebKit reads it through a private scheme.
final class SourceIconCache {
    static let scheme = "vaultclassifiersourceicon"
    private static let maximumBytes = 512 * 1_024
    private static let allowedContentTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/heic",
    ]

    private let directory: URL
    private var pendingKeys = Set<String>()

    init?(directory: URL?, retiredDirectory: URL? = nil) {
        guard let directory else { return nil }
        self.directory = directory
        do {
            if let retiredDirectory,
               FileManager.default.fileExists(atPath: retiredDirectory.path) {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: retiredDirectory)
                } else {
                    try FileManager.default.moveItem(at: retiredDirectory, to: directory)
                }
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            pruneIfNeeded()
        } catch {
            return nil
        }
    }

    func cachedURL(for remoteURL: String) -> URL? {
        let key = cacheKey(for: remoteURL)
        guard FileManager.default.fileExists(atPath: dataURL(for: key).path),
              FileManager.default.fileExists(atPath: typeURL(for: key).path),
              let url = URL(string: "\(Self.scheme)://cache/\(key)") else {
            return nil
        }
        return url
    }

    func cache(remoteURL: String, onCompletion: @escaping () -> Void) {
        let key = cacheKey(for: remoteURL)
        guard cachedURL(for: remoteURL) == nil, pendingKeys.insert(key).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingKeys.remove(key) }
            do {
                let downloaded = try await Self.download(remoteURL)
                try downloaded.data.write(to: self.dataURL(for: key), options: .atomic)
                try downloaded.contentType.data(using: .utf8)?.write(to: self.typeURL(for: key), options: .atomic)
                onCompletion()
            } catch {
                // Collection remains useful without an icon. Network and
                // decode failures are intentionally silent and non-blocking.
            }
        }
    }

    func response(for requestURL: URL) -> (data: Data, contentType: String)? {
        guard requestURL.scheme == Self.scheme,
              requestURL.host == "cache",
              let key = requestURL.pathComponents.last,
              key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let contentType = try? String(contentsOf: typeURL(for: key), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              Self.allowedContentTypes.contains(contentType),
              let data = try? Data(contentsOf: dataURL(for: key)),
              !data.isEmpty,
              data.count <= Self.maximumBytes else {
            return nil
        }
        return (data, contentType)
    }

    private func cacheKey(for remoteURL: String) -> String {
        SHA256.hash(data: Data(remoteURL.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func dataURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).data", isDirectory: false)
    }

    private func typeURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).type", isDirectory: false)
    }

    private static func download(_ remoteURL: String) async throws -> (data: Data, contentType: String) {
        guard let url = URL(string: remoteURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rawContentType = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first,
              allowedContentTypes.contains(rawContentType.lowercased()) else {
            throw URLError(.cannotDecodeContentData)
        }
        if response.expectedContentLength > Int64(maximumBytes) { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }
        return (data, rawContentType.lowercased())
    }

    private func pruneIfNeeded() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cachedImages = entries.filter { $0.pathExtension == "data" }
        guard cachedImages.count > 512 else { return }
        let oldest = cachedImages.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs < rhs
        }.prefix(cachedImages.count - 512)
        for dataFile in oldest {
            try? manager.removeItem(at: dataFile)
            try? manager.removeItem(at: dataFile.deletingPathExtension().appendingPathExtension("type"))
        }
    }
}

final class SourceIconSchemeHandler: NSObject, WKURLSchemeHandler {
    private let cache: SourceIconCache?

    init(cache: SourceIconCache?) {
        self.cache = cache
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let response = cache?.response(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": response.contentType,
            "Cache-Control": "private, max-age=31536000",
        ])!
        urlSchemeTask.didReceive(http)
        urlSchemeTask.didReceive(response.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
