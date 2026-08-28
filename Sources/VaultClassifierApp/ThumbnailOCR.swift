import Foundation
import Vision
import AppKit

/// On-device OCR of a video's thumbnail, used as extra classification evidence
/// so the model can read baked-in thumbnail text (titles, "DEBUNKED", model
/// names, etc.) instead of over-declining on a short title.
///
/// Local-first: OCR runs through Apple's Vision framework on this Mac; the only
/// network is fetching the PUBLIC thumbnail image (like grounded research pulls
/// public web). No user data leaves the device. Results are cached by video id.
actor ThumbnailOCR {
    static let shared = ThumbnailOCR()

    private var cache: [String: String] = [:]   // videoID -> recognized text ("" = tried, none)
    private let maxCacheEntries = 4_000

    /// The deterministic YouTube thumbnail URL for a video id (hqdefault always
    /// exists, unlike maxresdefault). Returns nil for a non-YouTube entry.
    static func youtubeVideoID(fromEntryID entryID: String) -> String? {
        // entryID shape: "youtube:video:<VIDEOID>"
        let parts = entryID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "youtube", parts[1] == "video" else { return nil }
        let id = String(parts[2])
        // YouTube ids are [A-Za-z0-9_-]{11}; guard against anything odd in a URL.
        guard !id.isEmpty, id.count <= 20, id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return id
    }

    /// Recognized thumbnail text for a YouTube entry, or nil if unavailable.
    func recognizedText(forEntryID entryID: String) async -> String? {
        guard let videoID = Self.youtubeVideoID(fromEntryID: entryID) else { return nil }
        if let cached = cache[videoID] { return cached.isEmpty ? nil : cached }
        guard let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg") else { return nil }
        let text = await Self.performOCR(url: url)
        if cache.count >= maxCacheEntries { cache.removeAll() }
        cache[videoID] = text ?? ""
        return text
    }

    private static func performOCR(url: URL) async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let request = VNRecognizeTextRequest { request, _ in
                    let lines = (request.results as? [VNRecognizedTextObservation])?
                        .compactMap { $0.topCandidates(1).first?.string } ?? []
                    let joined = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: joined.isEmpty ? nil : String(joined.prefix(800)))
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do { try handler.perform([request]) } catch { continuation.resume(returning: nil) }
            }
        }
    }
}
