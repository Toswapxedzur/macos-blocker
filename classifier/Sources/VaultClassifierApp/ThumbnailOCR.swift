import Foundation
import Vision
import AppKit
import VaultClassifierCore

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

    private var cache: [String: String] = [:]           // image URL -> recognized text ("" = tried, none)
    private var inFlight: [String: Task<String?, Never>] = [:]
    private let maxCacheEntries = 4_000

    /// The image to OCR for an entry: YouTube's deterministic thumbnail, or the
    /// collector-supplied cover when `ThumbnailURLPolicy` accepts it (Bilibili).
    static func imageURL(platformID: String, entryID: String, thumbnailURL: String?) -> URL? {
        ThumbnailURLPolicy.resolve(platformID: platformID, entryID: entryID, provided: thumbnailURL)
    }

    /// Recognized thumbnail text for an entry, or nil. Cached by image URL;
    /// concurrent callers for the same image await one shared OCR task.
    func recognizedText(platformID: String, entryID: String, thumbnailURL: String? = nil) async -> String? {
        guard let url = Self.imageURL(platformID: platformID, entryID: entryID, thumbnailURL: thumbnailURL) else { return nil }
        let key = url.absoluteString
        if let cached = cache[key] { return cached.isEmpty ? nil : cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task { await Self.performOCR(url: url) }
        inFlight[key] = task
        let text = await task.value
        inFlight[key] = nil
        if cache.count >= maxCacheEntries { cache.removeAll() }
        cache[key] = text ?? ""
        return text
    }

    /// Kick off OCR for a batch of entries with bounded concurrency so the
    /// network fetches overlap (they dominate the per-thumbnail cost). Results
    /// land in the cache; the per-entry `recognizedText` above then hits it or
    /// shares the in-flight task. Awaiting this is optional — callers can fire it
    /// and let the serial classify loop consume the warm cache.
    func prewarm(platformID: String, entries: [(entryID: String, thumbnailURL: String?)], maxConcurrent: Int = 6) async {
        let pending = entries.filter { entry in
            guard let url = Self.imageURL(platformID: platformID, entryID: entry.entryID, thumbnailURL: entry.thumbnailURL) else { return false }
            return cache[url.absoluteString] == nil
        }
        guard !pending.isEmpty else { return }
        var index = 0
        await withTaskGroup(of: Void.self) { group in
            func addNext() {
                guard index < pending.count else { return }
                let entry = pending[index]; index += 1
                group.addTask { [weak self] in
                    _ = await self?.recognizedText(platformID: platformID, entryID: entry.entryID, thumbnailURL: entry.thumbnailURL)
                }
            }
            for _ in 0..<min(maxConcurrent, pending.count) { addNext() }
            while await group.next() != nil { addNext() }
        }
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
