import XCTest
@testable import VaultClassifierApp

/// The coalescing policy at the engine boundary: single-item requests that
/// arrive while the engine is busy must be drained together as ONE batch (up to
/// the chunk size), never one lonely prefill each. Deterministic: everything is
/// MainActor and the only suspension points are the gates below.
@MainActor
final class ClassificationCoalescerTests: XCTestCase {
    /// Lets a test hold a `run` open (simulating a busy engine) and observe when
    /// it has been entered; `release()` lets it finish.
    @MainActor
    private final class Gate {
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var released = false
        private var entered = false

        func hold() async {
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            if released { return }
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredContinuation = $0 }
        }

        func release() {
            released = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    func testSingleItemRequestsArrivingWhileBusyDrainAsOneBatch() async {
        let engine = Gate()
        let idle = Gate()
        var batches: [[String]] = []
        let coalescer = ClassificationCoalescer<String>(chunkSize: 16, arrivalWindowNanoseconds: 0) { _, items in
            batches.append(items)
            if batches.count == 1 { await engine.hold() }   // engine busy on the first batch
        }
        coalescer.onIdle = { idle.release() }

        coalescer.enqueue(platformID: "youtube", items: ["v0"])
        await engine.waitUntilEntered()
        // Five separate one-item requests land while the engine is busy — the
        // live pattern (cards hydrate one per tick).
        for index in 1...5 { coalescer.enqueue(platformID: "youtube", items: ["v\(index)"]) }
        XCTAssertEqual(coalescer.pendingCount, 5, "arrivals wait; nothing runs alongside the busy engine")

        engine.release()
        await idle.hold()

        XCTAssertEqual(batches, [["v0"], ["v1", "v2", "v3", "v4", "v5"]], "the five stragglers are one multi-sequence pass, not five")
        XCTAssertEqual(coalescer.pendingCount, 0)
    }

    func testDrainChunksEverythingWaitingToTheChunkSize() async {
        let engine = Gate()
        let idle = Gate()
        var sizes: [Int] = []
        let coalescer = ClassificationCoalescer<String>(chunkSize: 16, arrivalWindowNanoseconds: 0) { _, items in
            sizes.append(items.count)
            if sizes.count == 1 { await engine.hold() }
        }
        coalescer.onIdle = { idle.release() }

        coalescer.enqueue(platformID: "youtube", items: ["seed"])
        await engine.waitUntilEntered()
        for index in 0..<40 { coalescer.enqueue(platformID: "youtube", items: ["v\(index)"]) }

        engine.release()
        await idle.hold()

        XCTAssertEqual(sizes, [1, 16, 16, 8], "40 waiting items drain as full chunks, then the remainder")
    }

    func testPlatformsNeverShareABatch() async {
        let engine = Gate()
        let idle = Gate()
        var batches: [(String, [String])] = []
        let coalescer = ClassificationCoalescer<String>(chunkSize: 16, arrivalWindowNanoseconds: 0) { platform, items in
            batches.append((platform, items))
            if batches.count == 1 { await engine.hold() }
        }
        coalescer.onIdle = { idle.release() }

        coalescer.enqueue(platformID: "youtube", items: ["y0"])
        await engine.waitUntilEntered()
        coalescer.enqueue(platformID: "youtube", items: ["y1"])
        coalescer.enqueue(platformID: "bilibili", items: ["b0"])
        coalescer.enqueue(platformID: "youtube", items: ["y2"])

        engine.release()
        await idle.hold()

        XCTAssertEqual(batches.map(\.0), ["youtube", "youtube", "bilibili"])
        XCTAssertEqual(batches[1].1, ["y1", "y2"], "same-platform stragglers merge; the other platform is its own pass")
        XCTAssertEqual(batches[2].1, ["b0"])
    }

    func testIdleArrivalWindowLetsNeighboursJoinBeforeTheEngineStarts() async {
        let idle = Gate()
        var batches: [[String]] = []
        // A real (short) window: the first card waits for the rest of the screen.
        let coalescer = ClassificationCoalescer<String>(chunkSize: 16, arrivalWindowNanoseconds: 30_000_000) { _, items in
            batches.append(items)
        }
        coalescer.onIdle = { idle.release() }

        coalescer.enqueue(platformID: "youtube", items: ["v0"])
        coalescer.enqueue(platformID: "youtube", items: ["v1"])
        coalescer.enqueue(platformID: "youtube", items: ["v2"])
        await idle.hold()

        XCTAssertEqual(batches, [["v0", "v1", "v2"]], "arrivals inside the window form one batch")
    }
}
