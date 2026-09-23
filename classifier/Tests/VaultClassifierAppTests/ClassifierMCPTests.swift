import Foundation
import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

/// The MCP surface is the page's own two halves. The catalog must name exactly
/// the dispatcher's actions with exactly the keys each reads — parsed from the
/// source, so a new page action without a catalog entry fails here.
@MainActor
final class ClassifierMCPTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        LocalStateFile.flushAllPendingWrites()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/VaultClassifierApp/\(file)"), encoding: .utf8)
    }

    private static func keys(in text: String) -> Set<String> {
        var found = Set<String>()
        for pattern in [#"key: "([a-zA-Z]+)""#, #"data\["([a-zA-Z]+)"\]"#] {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                found.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        return found
    }

    private static func functionBody(named name: String, in text: String) -> String {
        guard let start = text.range(of: "func \(name)(") else { return "" }
        var depth = 0
        var index = text[start.upperBound...].firstIndex(of: "{") ?? text.endIndex
        let bodyStart = index
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 } else if text[index] == "}" { depth -= 1; if depth == 0 { break } }
            index = text.index(after: index)
        }
        return String(text[bodyStart..<index])
    }

    func testCatalogMatchesTheDispatcherSource() throws {
        let shell = try Self.source("VaultClassifierViewModel+WebShell.swift")
        let settings = try Self.source("VaultClassifierViewModel+Settings.swift")
        let dispatcher = Self.functionBody(named: "performWebAction", in: shell)
        let caseRegex = try NSRegularExpression(pattern: #"case "([a-zA-Z]+)":"#)
        let matches = caseRegex.matches(in: dispatcher, range: NSRange(dispatcher.startIndex..., in: dispatcher))
        var expected: [String: Set<String>] = [:]
        for (offset, match) in matches.enumerated() {
            let name = String(dispatcher[Range(match.range(at: 1), in: dispatcher)!])
            let blockStart = Range(match.range, in: dispatcher)!.upperBound
            let blockEnd = offset + 1 < matches.count ? Range(matches[offset + 1].range, in: dispatcher)!.lowerBound : dispatcher.endIndex
            let block = String(dispatcher[blockStart..<blockEnd])
            var keys = Self.keys(in: block)
            // Two actions parse their form through helpers in the Settings file.
            for helper in ["parseClassifierTypeLocalModelWebInput", "parseClassifierTypeResearchWebInput"] where block.contains(helper) {
                keys.formUnion(Self.keys(in: Self.functionBody(named: helper, in: settings)))
            }
            expected[name] = keys
        }
        XCTAssertFalse(expected.isEmpty)
        let catalog = Dictionary(ClassifierWebActionCatalog.actions.map { ($0.name, Set($0.keys)) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(Set(catalog.keys), Set(expected.keys), "catalog names must equal the dispatcher's cases")
        for (name, keys) in expected {
            XCTAssertEqual(catalog[name], keys, "keys for \(name)")
        }
        for action in ClassifierWebActionCatalog.actions {
            XCTAssertFalse(action.summary.isEmpty, "\(action.name) needs a summary")
        }
    }

    func testSnapshotSectionsAndOverview() throws {
        let vm = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        let overview = try XCTUnwrap(vm.mcpSnapshot(section: nil))
        XCTAssertNotNil(overview["settings"])
        XCTAssertNotNil(overview["classifierTypes"])
        XCTAssertNotNil(overview["assetCounts"])
        XCTAssertNil(overview["assets"], "the overview never carries the multi-megabyte assets")
        let types = try XCTUnwrap(vm.mcpSnapshot(section: "assets.classifierTypes"))
        XCTAssertEqual(Set(types.keys), ["assets.classifierTypes"])
        let settings = try XCTUnwrap(vm.mcpSnapshot(section: "settings"))
        XCTAssertNotNil((settings["settings"] as? [String: Any])?["localLLM"])
        let all = try XCTUnwrap(vm.mcpSnapshot(section: "all"))
        XCTAssertEqual(Set(all.keys), Set(vm.webSnapshot().keys))
        XCTAssertNil(vm.mcpSnapshot(section: "nope"))
        XCTAssertNil(vm.mcpSnapshot(section: "assets.nope"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(overview))
    }

    func testPerformRoutesThroughTheDispatcherWithItsValidation() throws {
        let vm = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        let created = vm.mcpPerform(action: "createClassifierType", data: ["name": "X posts", "platformID": "twitter"])
        XCTAssertTrue(created.rerender); XCTAssertNil(created.issue)
        let types = try XCTUnwrap((vm.mcpSnapshot(section: "assets.classifierTypes")?["assets.classifierTypes"]) as? [[String: Any]])
        XCTAssertTrue(types.contains { ($0["name"] as? String) == "X posts" && ($0["applicablePlatformID"] as? String) == "twitter" })
        let rejected = vm.mcpPerform(action: "createClassifierType", data: ["name": "", "platformID": "twitter"])
        XCTAssertNotNil(rejected.issue, "the page's validation applies unchanged")
        let unknown = vm.mcpPerform(action: "definitely-not-an-action", data: [:])
        XCTAssertNotNil(unknown.issue)
    }
}
