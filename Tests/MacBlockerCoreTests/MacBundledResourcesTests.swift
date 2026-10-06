import Foundation
import XCTest
@testable import MacBlockerCore

final class MacBundledResourcesTests: XCTestCase {
    func testInstalledAppAndAdjacentSwiftPMResourcesWithoutBuildFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for base in [root.appendingPathComponent("Relocated.app/Contents/Resources"), root.appendingPathComponent("swift-bin")] {
            for (target, folder) in [("MacBlockerPanel", "Resources"), ("MacBlockerCore", "Resources"), ("MacBlockerWebUI", "WebAssets")] {
                let directory = base.appendingPathComponent("macosBlocker_\(target).bundle/\(folder)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                XCTAssertEqual(MacBundledResources.directory(target: target, subdirectory: folder, roots: [base]), directory)
            }
        }
        XCTAssertNil(MacBundledResources.directory(target: "MacBlockerCore", subdirectory: "Resources", roots: [root.appendingPathComponent("missing")]))
    }

    func testActualBundledJavaScriptAndMissingResource() throws {
        let url = try XCTUnwrap(RuntimeResources.url(name: "group-actions", ext: "js"))
        XCTAssertTrue(try String(contentsOf: url).contains("CBGroupActions"))
        XCTAssertNil(RuntimeResources.url(name: "not-a-resource", ext: "js"))
    }
}
