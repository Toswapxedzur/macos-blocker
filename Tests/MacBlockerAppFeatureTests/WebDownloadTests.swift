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
    func testRealAppSchemeRuleLogExportAndCollision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = directory.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let shim = try XCTUnwrap(WebAssetsLocator.assetsDirectory).appendingPathComponent("chrome-shim.js")
        try FileManager.default.copyItem(at: shim, to: assets.appendingPathComponent("chrome-shim.js"))
        let html = """
        <html><body><script src="chrome-shim.js"></script><script>
        window.__cbSaveRuleLog('blocker-logs-fixture.txt','selected rule\\nsecond entry').then(async r=>{
          window.firstReply=r;
          window.secondReply=await window.__cbSaveRuleLog('blocker-logs-fixture.txt','second export');
        });
        </script></body></html>
        """
        try Data(html.utf8).write(to: assets.appendingPathComponent("popup.html"))
        let store = BlockerWebStore(shared: SharedAppGroupStore(baseDirectory: directory.appendingPathComponent("store")))
        let coordinator = BlockerWebView.Coordinator(store: store, ruleLogJSON: nil, onClearRuleLog: nil,
            onStorePersisted: nil, onRunCustomGroup: nil, onSnoozePress: nil, clustersJSON: nil,
            onLinkRequest: nil, tagNames: nil, scenes: [], downloadDirectory: directory)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(coordinator, name: "cbBridge")
        let handler = WebAssetSchemeHandler(assetsDirectory: assets)
        config.setURLSchemeHandler(handler, forURLScheme: WebAssetSchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: config)
        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        webView.load(URLRequest(url: WebAssetSchemeHandler.indexURL))
        let first = directory.appendingPathComponent("blocker-logs-fixture.txt")
        let second = directory.appendingPathComponent("blocker-logs-fixture (2).txt")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: second.path) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(try String(contentsOf: first), "selected rule\nsecond entry")
        XCTAssertEqual(try String(contentsOf: second), "second export")
        let replies = try await webView.evaluateJavaScript("[window.firstReply.ok,window.secondReply.ok]") as? [Bool]
        XCTAssertEqual(replies, [true,true])
        XCTAssertThrowsError(try coordinator.saveRuleLog(filename: "../outside.txt", text: "denied"))
        XCTAssertThrowsError(try coordinator.saveRuleLog(filename: "blocker-logs-fixture.command", text: "denied"))
        XCTAssertThrowsError(try coordinator.saveRuleLog(filename: "blocker-logs-large.txt", text: String(repeating: "é", count: 4 * 1024 * 1024 + 1)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("blocker-logs-large.txt").path))
        config.userContentController.removeScriptMessageHandler(forName: "cbBridge")
        withExtendedLifetime((webView, coordinator, handler)) {}
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
