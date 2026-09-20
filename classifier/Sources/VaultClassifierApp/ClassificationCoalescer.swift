import Foundation

/// Batches classification work at the engine boundary — the one place that
/// knows what is *waiting*.
///
/// Live requests arrive one card at a time (the page hydrates cards in
/// separate ticks, so the extension's per-tick batcher sees one item each), and
/// the engine serializes everything on a single llama context. Without this
/// queue each single-item request ran alone, paying the full unbatchable prompt
/// prefill by itself. Policy:
///
/// * If the engine is busy when a request arrives, the items just join the
///   pending queue; nothing else happens.
/// * When the engine frees, drain **everything waiting**, up to `chunkSize` per
///   multi-sequence pass, and keep draining until the queue is empty — items
///   that arrive mid-drain join the next pass.
/// * When idle, the first arrival waits a short `arrivalWindow` so its
///   neighbours (the rest of the screen) can join it before the engine starts.
///
/// Items are grouped by platform because the pipeline classifies per platform.
/// Deduplication is not this type's job; callers filter in-flight items first.
@MainActor
final class ClassificationCoalescer<Item> {
    typealias Run = (_ platformID: String, _ items: [Item]) async -> Void

    let chunkSize: Int
    let arrivalWindowNanoseconds: UInt64
    /// Fired each time a drain empties the queue and the engine goes idle.
    var onIdle: (() -> Void)?

    private let run: Run
    private var pending: [(platformID: String, items: [Item])] = []
    private var isDraining = false
    private var arrivalTask: Task<Void, Never>?

    init(chunkSize: Int, arrivalWindowNanoseconds: UInt64, run: @escaping Run) {
        self.chunkSize = max(1, chunkSize)
        self.arrivalWindowNanoseconds = arrivalWindowNanoseconds
        self.run = run
    }

    /// Items waiting for the engine (not counting the chunk currently running).
    var pendingCount: Int { pending.reduce(0) { $0 + $1.items.count } }

    func enqueue(platformID: String, items: [Item]) {
        guard !items.isEmpty else { return }
        if let index = pending.firstIndex(where: { $0.platformID == platformID }) {
            pending[index].items.append(contentsOf: items)
        } else {
            pending.append((platformID: platformID, items: items))
        }
        // A running drain picks these up on its next pass; a scheduled arrival
        // window will take them when it fires. Only an idle queue starts one.
        guard !isDraining, arrivalTask == nil else { return }
        let window = arrivalWindowNanoseconds
        arrivalTask = Task { [weak self] in
            if window > 0 { try? await Task.sleep(nanoseconds: window) }
            guard let self else { return }
            self.arrivalTask = nil
            await self.drain()
        }
    }

    /// Up to `chunkSize` of the earliest-seen platform's waiting items.
    private func takeChunk() -> (platformID: String, items: [Item])? {
        guard let index = pending.firstIndex(where: { !$0.items.isEmpty }) else {
            pending.removeAll()
            return nil
        }
        let platformID = pending[index].platformID
        let take = min(chunkSize, pending[index].items.count)
        let items = Array(pending[index].items.prefix(take))
        pending[index].items.removeFirst(take)
        if pending[index].items.isEmpty { pending.remove(at: index) }
        return (platformID: platformID, items: items)
    }

    private func drain() async {
        isDraining = true
        // Every pass re-reads the queue, so anything that arrived while the
        // previous chunk ran is batched into this one — "batch all waiting".
        while let chunk = takeChunk() {
            await run(chunk.platformID, chunk.items)
        }
        isDraining = false
        onIdle?()
    }
}
