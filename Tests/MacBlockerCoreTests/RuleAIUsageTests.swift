import XCTest
import VaultClassifierCore
@testable import MacBlockerCore

final class RuleAIUsageTests: XCTestCase {
    func testSharedAllowanceSurvivesRestartLinkAndUnlinkWithoutDoubleCounting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json"), now = Date(timeIntervalSince1970: 86400 * 20000)
        let ledger = RuleAIUsage(url: url)
        try ledger.reserve(members: ["mac:a"], limit: 3, now: now)
        try ledger.reserve(members: ["chrome:b"], limit: 3, now: now)
        try ledger.reserve(members: ["mac:a", "chrome:b"], limit: 3, now: now)
        XCTAssertThrowsError(try RuleAIUsage(url: url).reserve(members: ["mac:a", "chrome:b"], limit: 3, now: now)) { XCTAssertEqual($0 as? RuleAIError, .usageLimit) }
        // Detaching retains that member's own call and the shared reservation.
        try ledger.reserve(members: ["mac:a"], limit: 3, now: now)
        XCTAssertThrowsError(try ledger.reserve(members: ["mac:a"], limit: 3, now: now))
        try ledger.reserve(members: ["chrome:b"], limit: 3, now: now)
        try ledger.reserve(members: ["mac:a"], limit: 1, now: now.addingTimeInterval(86400))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testCorruptOrUnwritableLedgerRefusesWithoutReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage.json")
        try Data("original corrupt data".utf8).write(to: url)
        XCTAssertThrowsError(try RuleAIUsage(url: url).reserve(members: ["mac:a"], limit: nil))
        XCTAssertEqual(try String(contentsOf: url), "original corrupt data")
    }
}
