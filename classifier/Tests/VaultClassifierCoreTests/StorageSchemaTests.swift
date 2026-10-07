import Foundation
import XCTest
@testable import VaultClassifierCore

final class StorageSchemaTests: XCTestCase {
    func testAppMajorsBoundMigrationsIndependentlyOfSchemaNumbers() throws {
        let v1 = StorageMetadata(format: "fixture", schemaVersion: 1, writer: .init(product: "mac", appVersion: "1.8.0"))
        let v2 = StorageSchemaPolicy(format: "fixture", currentSchema: 2, writer: .init(product: "mac", appVersion: "2.0.0"))
        XCTAssertNoThrow(try v2.validate(v1))
        let v3 = StorageSchemaPolicy(format: "fixture", currentSchema: 2, writer: .init(product: "mac", appVersion: "3.0.0"))
        XCTAssertThrowsError(try v3.validate(v1))
        let previous = StorageMetadata(format: "fixture", schemaVersion: 1, writer: .init(product: "mac", appVersion: "2.9.0"))
        XCTAssertNoThrow(try v3.validate(previous))
        let unchanged = StorageSchemaPolicy(format: "fixture", writer: .init(product: "mac", appVersion: "4.0.0"))
        XCTAssertNoThrow(try unchanged.validate(v1), "same format needs no transformation")
        XCTAssertThrowsError(try unchanged.validate(nil), "bounded alpha intake has expired")
    }

    func testEnvelopePreservesPayloadAndRejectsWrongOrFutureFormats() throws {
        let policy = StorageSchemaPolicy(format: "fixture", writer: .init(product: "mac", appVersion: "2.2.7"))
        let payload = Data(#"{"list":[1,2],"name":"保持"}"#.utf8)
        let wrapped = try policy.wrap(payload)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: policy.payload(from: wrapped)) as? NSDictionary, try JSONSerialization.jsonObject(with: payload) as? NSDictionary)
        XCTAssertThrowsError(try StorageSchemaPolicy(format: "wrong").payload(from: wrapped))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: wrapped) as? [String: Any])
        var header = try XCTUnwrap(object["storageMetadata"] as? [String: Any]); header["schemaVersion"] = 99; object["storageMetadata"] = header
        XCTAssertThrowsError(try policy.payload(from: JSONSerialization.data(withJSONObject: object)))
    }

    func testNativeWriterUsesHostProductNotClassifierVersion() {
        #if os(Windows)
        XCTAssertEqual(StorageProduct.current.product, "windows")
        #else
        XCTAssertEqual(StorageProduct.current.product, "mac")
        #endif
        XCTAssertGreaterThanOrEqual(StorageProduct.current.major, 0)
    }

    func testLateStateSaveCannotOverwriteNewerDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json"), file = LocalStateFile(url: root.appendingPathComponent("state.json"))
        let state = try file.load()
        let bytes = Data(#"{"schemaVersion":99,"future":{"keep":true}}"#.utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try file.save(state))
        file.flushSynchronously()
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testFlatStoreRejectsInvalidVersionsAndProtectsOpaqueFields() throws {
        let policy = StorageSchemaPolicy(format: "vault.web-store", currentSchema: 3)
        for invalid in [true, -1, 4, 1.5, "3", NSNull()] as [Any] { XCTAssertThrowsError(try policy.validateFlat(["schemaVersion": invalid])) }
        let raw: [String: Any] = ["schemaVersion": 2, "blockedGroups": [["id": "one"]], "cbRuleState": ["one": ["private": "保持"]]]
        let next = try policy.stampFlat(raw)
        XCTAssertEqual(next["cbRuleState"] as? NSDictionary, raw["cbRuleState"] as? NSDictionary)
        XCTAssertEqual(try policy.stampFlat(next) as NSDictionary, next as NSDictionary)
    }
}
