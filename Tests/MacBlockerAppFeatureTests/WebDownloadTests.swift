#if os(macOS)
import XCTest
import WebKit
@testable import MacBlockerWebUI
import MacBlockerCore

final class WebDownloadTests: XCTestCase {
    func testDestinationsStayInsideDownloadsAndPreserveExistingAndActiveFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try BlockerWebView.Coordinator.availableDownloadURL(in: directory, suggestedFilename: "../logs.txt")
        XCTAssertEqual(first, directory.appendingPathComponent("logs.txt"))
        try Data("keep".utf8).write(to: first)
        let second = try BlockerWebView.Coordinator.availableDownloadURL(in: directory, suggestedFilename: "logs.txt")
        XCTAssertEqual(second.lastPathComponent, "logs (2).txt")
        let third = try BlockerWebView.Coordinator.availableDownloadURL(in: directory, suggestedFilename: "logs.txt", reserved: [second])
        XCTAssertEqual(third.lastPathComponent, "logs (3).txt")
        XCTAssertEqual(try String(contentsOf: first), "keep")
        XCTAssertEqual(try BlockerWebView.Coordinator.availableDownloadURL(in: directory, suggestedFilename: "..").lastPathComponent, "download.txt")
    }

    @MainActor
    func testRealWebKitBlobDownloadWithImmediateRevocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory.appendingPathComponent("store")))
        let coordinator = BlockerWebView.Coordinator(store: store, ruleLogJSON: nil, onClearRuleLog: nil,
            onStorePersisted: nil, onRunCustomGroup: nil, onSnoozePress: nil, clustersJSON: nil,
            onLinkRequest: nil, tagNames: nil, scenes: [], downloadDirectory: directory)
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = coordinator
        webView.loadHTMLString("""
        <html><body><script>
        const b=new Blob(['isolated rule log\\nsecond entry'],{type:'text/plain'});
        const u=URL.createObjectURL(b);const a=document.createElement('a');
        a.href=u;a.download='blocker-logs-fixture.txt';a.click();URL.revokeObjectURL(u);
        </script></body></html>
        """, baseURL: nil)
        let destination = directory.appendingPathComponent("blocker-logs-fixture.txt")
        for _ in 0..<100 {
            if (try? String(contentsOf: destination)) == "isolated rule log\nsecond entry" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(try String(contentsOf: destination), "isolated rule log\nsecond entry")
        withExtendedLifetime((webView, coordinator)) {}
    }
}
#endif
