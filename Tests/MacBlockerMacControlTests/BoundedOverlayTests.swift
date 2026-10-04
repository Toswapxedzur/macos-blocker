import XCTest
@testable import MacBlockerMacControl
#if canImport(AppKit)
import AppKit
import SwiftUI
import MacBlockerCore

final class BoundedOverlayTests: XCTestCase {
    func testLongDocumentRemainsReachableInsideBoundedViewport() async {
        await MainActor.run {
            final class Content: NSView {
                override var fittingSize: NSSize { NSSize(width: 300, height: 4000) }
            }
            let content = Content()
            let scroll = BoundedOverlayScrollView(document: content)
            let size = scroll.fittedSize(maximumHeight: 480)
            XCTAssertEqual(size.height, 480)
            XCTAssertEqual(content.frame.height, 4000)
            XCTAssertTrue(scroll.hasVerticalScroller)
            scroll.setFrameSize(size)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 3520))
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 3000)
        }
    }

    func testShortListKeepsItsNaturalHeight() async {
        await MainActor.run {
            final class Content: NSView {
                override var fittingSize: NSSize { NSSize(width: 300, height: 75) }
            }
            let scroll = BoundedOverlayScrollView(document: Content())
            XCTAssertEqual(scroll.fittedSize(maximumHeight: 480), NSSize(width: 300, height: 75))
        }
    }

    func testTimerRosterRotatesWithoutGrowingPastScreen() async throws {
        let controller = await MainActor.run { TimerOverlayPanelController() }
        let first = await MainActor.run { () -> NSPanel? in
            _ = NSApplication.shared
            let before = Set(NSApp.windows.map(\.windowNumber))
            controller.update(rows: (0..<10000).map { TimerOverlayRow(id: String($0), name: "Timer " + String($0), remainingSeconds: 600) })
            return NSApp.windows.first { !before.contains($0.windowNumber) && $0 is NSPanel } as? NSPanel
        }
        let panel = try XCTUnwrap(first)
        await MainActor.run {
            let work = NSScreen.main!.visibleFrame
            XCTAssertTrue(work.contains(panel.frame))
            XCTAssertTrue(panel.ignoresMouseEvents)
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            let hosting = panel.contentView as! NSHostingView<TimerOverlayView>
            XCTAssertEqual(hosting.rootView.model.rows.first?.id, "0")
            XCTAssertLessThan(hosting.rootView.model.rows.count, 100)
        }
        try await Task.sleep(nanoseconds: 5_300_000_000)
        await MainActor.run {
            let hosting = panel.contentView as! NSHostingView<TimerOverlayView>
            XCTAssertNotEqual(hosting.rootView.model.rows.first?.id, "0")
            controller.update(rows: [TimerOverlayRow(id: "long", name: String(repeating: "W", count: 500), remainingSeconds: 600)])
            XCTAssertTrue(NSScreen.main!.visibleFrame.contains(panel.frame))
            XCTAssertEqual(hosting.rootView.model.rows.first?.formattedRemaining, "00:10:00")
            controller.update(rows: [])
            XCTAssertFalse(panel.isVisible)
            XCTAssertTrue(hosting.rootView.model.rows.isEmpty)
            controller.teardown()
        }
    }

    func testProductionLazyPanelStackKeepsEveryPanelInBoundedViewport() async throws {
        let panels = try (0..<30).map { index in
            try JSONDecoder().decode(PanelSnapshot.self, from: Data("{\"id\":\"panel-\(index)\",\"title\":\"Panel \(index)\",\"controls\":[{\"id\":\"text\",\"type\":\"text\",\"text\":\"Row text\"}]}".utf8))
        }
        await MainActor.run {
            let model = PanelOverlayModel()
            model.panels = panels
            model.viewportHeight = 480
            let hosting = NSHostingView(rootView: PanelOverlayView(model: model))
            let scroll = BoundedOverlayScrollView(document: hosting)
            let size = scroll.fittedSize(maximumHeight: 480)
            XCTAssertEqual(size.height, 480)
            XCTAssertLessThanOrEqual(hosting.frame.height, 480)
            XCTAssertEqual(model.panels.count, 30)
        }
    }
}
#endif
