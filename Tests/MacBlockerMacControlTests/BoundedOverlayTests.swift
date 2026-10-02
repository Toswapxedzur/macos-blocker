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
