import Foundation
import Vision
import AppKit

/// On-device OCR of a video's thumbnail, used as extra classification evidence
/// so the model can read baked-in thumbnail text (titles, "DEBUNKED", model
/// names, etc.) instead of over-declining on a short title.
///
/// Local-first: OCR runs through Apple's Vision framework on this Mac; the only
/// network is fetching the PUBLIC thumbnail image (like grounded research pulls
/// public web). No user data leaves the device. Results are cached by video id,
/// concurrent calls for the same id share one fetch, and a whole batch can be
/// prewarmed with bounded concurrency (fetch is network-bound, so this is the
/// big speedup over serial per-video OCR).
actor ThumbnailOCR {
    static let shared = ThumbnailOCR()

    private var cache: [String: String] = [:]           // videoID -> recognized text ("" = tried, none)
    private var inFlight: [String: Task<String?, Never>] = [:]
    private let maxCacheEntries = 4_000

    /// The deterministic YouTube thumbnail video id from an entry id, or nil.
    static func youtubeVideoID(fromEntryID entryID: String) -> String? {
        // entryID shape: "youtube:video:<VIDEOID>"
        let parts = entryID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "youtube", parts[1] == "video" else { return nil }
        let id = String(parts[2])
        guard !id.isEmpty, id.count <= 20, id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return id
    }

    /// Recognized thumbnail text for a YouTube entry, or nil. Cached; concurrent
    /// callers for the same id await one shared OCR task (no double fetch).
    func recognizedText(forEntryID entryID: String) async -> String? {
        guard let videoID = Self.youtubeVideoID(fromEntryID: entryID) else { return nil }
        if let cached = cache[videoID] { return cached.isEmpty ? nil : cached }
        if let existing = inFlight[videoID] { return await existing.value }

        let task = Task { await Self.performOCR(videoID: videoID) }
        inFlight[videoID] = task
        let text = await task.value
        inFlight[videoID] = nil
        if cache.count >= maxCacheEntries { cache.removeAll() }
        cache[videoID] = text ?? ""
        return text
    }

    /// Kick off OCR for a batch of entries with bounded concurrency so the
    /// network fetches overlap (they dominate the per-thumbnail cost). Results
    /// land in the cache; the per-video `recognizedText` above then hits it or
    /// shares the in-flight task. Awaiting this is optional — callers can fire it
    /// and let the serial classify loop consume the warm cache.
    func prewarm(entryIDs: [String], maxConcurrent: Int = 6) async {
        let ids = entryIDs.filter { entry in
            guard let v = Self.youtubeVideoID(fromEntryID: entry) else { return false }
            return cache[v] == nil
        }
        guard !ids.isEmpty else { return }
        var index = 0
        await withTaskGroup(of: Void.self) { group in
            func addNext() {
                guard index < ids.count else { return }
                let entry = ids[index]; index += 1
                group.addTask { [weak self] in _ = await self?.recognizedText(forEntryID: entry) }
            }
            for _ in 0..<min(maxConcurrent, ids.count) { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    private static func performOCR(videoID: String) async -> String? {
        guard let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"),
              let (data, response) = try? await URLSession.shared.data(from: url),
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
