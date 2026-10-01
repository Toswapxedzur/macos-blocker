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
                let helperBody = Self.functionBody(named: helper, in: settings)
                keys.formUnion(Self.keys(in: helperBody))
                let countRegex = try NSRegularExpression(pattern: #"tagCount\("([a-zA-Z]+)""#)
                for match in countRegex.matches(in: helperBody, range: NSRange(helperBody.startIndex..., in: helperBody)) {
                    keys.insert(String(helperBody[Range(match.range(at: 1), in: helperBody)!]))
                }
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
        XCTAssertNotNil((settings["settings"] as? [String: Any])?["localModels"])
        let all = try XCTUnwrap(vm.mcpSnapshot(section: "all"))
        XCTAssertEqual(Set(all.keys), Set(vm.webSnapshot().keys))
        XCTAssertNil(vm.mcpSnapshot(section: "nope"))
        XCTAssertNil(vm.mcpSnapshot(section: "assets.nope"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(overview))
    }

    func testRoutineGroupEditsPersistThroughMCP() throws {
        let vm = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        XCTAssertNil(vm.mcpPerform(action: "createClassifierType", data: ["name": "A", "platformIDs": ["youtube"]]).issue)
        let group = try XCTUnwrap(vm.localState?.workspaceCatalog.classifierTypes.first)
        XCTAssertNil(vm.mcpPerform(action: "saveClassifierTypeLocalModel", data: [
            "typeID": group.id, "speedQuality": "balanced", "strictness": "4", "houseRules": "Use my group vocabulary."
        ]).issue)
        LocalStateFile.flushAllPendingWrites()
        let reopened = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        XCTAssertEqual(reopened.localState?.workspaceCatalog.classifierTypes.first?.localModel.strictness, .broad)
        XCTAssertEqual(reopened.localState?.workspaceCatalog.classifierTypes.first?.localModel.houseRules, "Use my group vocabulary.")
    }

    func testPerformRoutesThroughTheDispatcherWithItsValidation() throws {
        let vm = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        let created = vm.mcpPerform(action: "createClassifierType", data: ["name": "X posts", "platformIDs": ["twitter"]])
        XCTAssertTrue(created.rerender); XCTAssertNil(created.issue)
        let types = try XCTUnwrap((vm.mcpSnapshot(section: "assets.classifierTypes")?["assets.classifierTypes"]) as? [[String: Any]])
        XCTAssertTrue(types.contains { ($0["name"] as? String) == "X posts" && ($0["applicablePlatformIDs"] as? [String]) == ["twitter"] })
        let rejected = vm.mcpPerform(action: "createClassifierType", data: ["name": "", "platformIDs": ["twitter"]])
        XCTAssertNotNil(rejected.issue, "the page's validation applies unchanged")
        let unknown = vm.mcpPerform(action: "definitely-not-an-action", data: [:])
        XCTAssertNotNil(unknown.issue)
    }

    /// A type takes several classifiable platforms (owner 2026-09-30); a platform
    /// that cannot be classified, or that another type holds, is refused.
    func testATypeTakesSeveralClassifiablePlatformsEachHeldOnce() throws {
        let vm = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        let types = { () throws -> [[String: Any]] in
            try XCTUnwrap((vm.mcpSnapshot(section: "assets.classifierTypes")?["assets.classifierTypes"]) as? [[String: Any]])
        }
        let before = try types().count
        XCTAssertEqual(vm.mcpPerform(action: "createClassifierType", data: ["name": "Empty", "platformIDs": []]).issue,
                       "Select at least one platform.")
        XCTAssertEqual(try types().count, before)
        XCTAssertNil(vm.mcpPerform(action: "createClassifierType", data: ["name": "Videos", "platformIDs": ["reddit", "bilibili"]]).issue)
        let videos = try XCTUnwrap(try types().first { ($0["name"] as? String) == "Videos" })
        XCTAssertEqual(videos["applicablePlatformIDs"] as? [String], ["reddit", "bilibili"])

        XCTAssertNotNil(vm.mcpPerform(action: "createClassifierType", data: ["name": "Feeds", "platformIDs": ["facebook"]]).issue,
                        "Facebook is collected but not classified")
        XCTAssertNotNil(vm.mcpPerform(action: "createClassifierType", data: ["name": "Clash", "platformIDs": ["bilibili"]]).issue,
                        "Bilibili belongs to Videos")
        XCTAssertEqual(try types().count, before + 1)

        let id = try XCTUnwrap(videos["id"] as? String)
        let changedPlatforms = vm.mcpPerform(action: "configureClassifierType", data: ["typeID": id, "name": "Changed", "applicablePlatformIDs": ["bilibili"]])
        XCTAssertEqual(changedPlatforms.issue, "Platforms cannot be changed after the group is created.")
        XCTAssertEqual(try types().first { ($0["id"] as? String) == id }?["name"] as? String, "Videos")
        XCTAssertEqual(try types().first { ($0["id"] as? String) == id }?["applicablePlatformIDs"] as? [String], ["reddit", "bilibili"])

        XCTAssertNil(vm.mcpPerform(action: "configureClassifierType", data: ["typeID": id, "name": "Videos and posts"]).issue)
        let renamed = try XCTUnwrap(try types().first { ($0["id"] as? String) == id })
        XCTAssertEqual(renamed["name"] as? String, "Videos and posts")
        XCTAssertEqual(renamed["applicablePlatformIDs"] as? [String], ["reddit", "bilibili"])
    }
}
