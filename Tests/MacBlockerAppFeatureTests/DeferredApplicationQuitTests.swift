#if os(macOS)
import AppKit
import XCTest
@testable import MacBlockerAppFeature

@MainActor
final class DeferredApplicationQuitTests: XCTestCase {
    func testWarningCancelLeavesAdmissionAndResourcesRunning() async {
        let quit = DeferredApplicationQuit()
        var events: [String] = []
        let result = quit.request(confirm: { events.append("cancel"); return false },
            shutdown: { events.append("stop-admission"); events.append("free-resources") }, reply: { events.append("reply") })
        XCTAssertEqual(result, .terminateCancel)
        XCTAssertNil(quit.task)
        await Task.yield()
        XCTAssertEqual(events, ["cancel"])
    }
    func testRepeatedQuitDefersOnceAndRepliesOnlyAfterCleanupAndFlush() async {
        let quit = DeferredApplicationQuit()
        var events: [String] = []
        var gate: CheckedContinuation<Void, Never>?
        let first = quit.request(confirm: { events.append("confirm"); return true }, shutdown: {
            events.append("stop-admission")
            await withCheckedContinuation { gate = $0 }
            events.append("free-resources")
            events.append("flush")
        }, reply: { events.append("reply") })
        XCTAssertEqual(first, .terminateLater)
        while gate == nil { await Task.yield() }
        let second = quit.request(confirm: { XCTFail("must not show warning twice"); return true },
            shutdown: { XCTFail("must not start cleanup twice") }, reply: { XCTFail("must not reply twice") })
        XCTAssertEqual(second, .terminateLater)
        XCTAssertEqual(events, ["confirm", "stop-admission"])
        gate?.resume()
        await quit.task?.value
        XCTAssertEqual(events, ["confirm", "stop-admission", "free-resources", "flush", "reply"])
    }
}
#endif
