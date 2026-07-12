import Foundation
import XCTest
@testable import MacBlockerCore

final class LocalFileBrokerTests: XCTestCase {
    func testTextJsonAndDirectoryOperationsRoundTrip() throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let broker = LocalFileBroker(baseURL: baseURL)

        let write = broker.handle(action: "write", path: "notes/focus.txt", text: "start", requestID: "write")
        XCTAssertEqual(write["ok"], "true")
        XCTAssertEqual(write["eventName"], "write")
        XCTAssertEqual(write["bytes"], "5")

        let append = broker.handle(action: "append", path: "notes/focus.txt", text: "+more", requestID: "append")
        XCTAssertEqual(append["ok"], "true")
        XCTAssertEqual(append["eventName"], "append")
        XCTAssertEqual(append["bytes"], "10")

        let read = broker.handle(action: "read", path: "notes/focus.txt", text: nil, requestID: "read")
        XCTAssertEqual(read["ok"], "true")
        XCTAssertEqual(read["eventName"], "read")
        XCTAssertEqual(read["text"], "start+more")
        XCTAssertEqual(read["bytes"], "10")

        let writeJson = broker.handle(
            action: "writeJson",
            path: "config/focus.json",
            text: #"{"enabled":true,"limit":25}"#,
            requestID: "write-json"
        )
        XCTAssertEqual(writeJson["ok"], "true")
        XCTAssertEqual(writeJson["eventName"], "write")

        let readJson = broker.handle(action: "readJson", path: "config/focus.json", text: nil, requestID: "read-json")
        XCTAssertEqual(readJson["ok"], "true")
        let valueData = try XCTUnwrap(readJson["valueJSON"]?.data(using: .utf8))
        let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: valueData) as? [String: Any])
        XCTAssertEqual(value["enabled"] as? Bool, true)
        XCTAssertEqual(value["limit"] as? Int, 25)

        let exists = broker.handle(action: "exists", path: "config/missing.json", text: nil, requestID: "exists")
        XCTAssertEqual(exists["ok"], "true")
        XCTAssertEqual(exists["exists"], "false")

        let list = broker.handle(action: "list", path: "", text: nil, requestID: "list")
        XCTAssertEqual(list["ok"], "true")
        let entriesData = try XCTUnwrap(list["entriesJSON"]?.data(using: .utf8))
        let entries = try XCTUnwrap(try JSONSerialization.jsonObject(with: entriesData) as? [[String: String]])
        XCTAssertEqual(entries.map { $0["name"] }, ["config", "notes"])
        XCTAssertEqual(entries.map { $0["kind"] }, ["directory", "directory"])
    }

    func testRejectsUnsafePathsInvalidJsonAndOversizedFiles() throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let broker = LocalFileBroker(baseURL: baseURL)

        for path in ["../private.txt", "/tmp/private.txt", ".hidden.txt", "notes/focus.md", "https://example.com/file.txt"] {
            let result = broker.handle(action: "read", path: path, text: nil, requestID: path)
            XCTAssertEqual(result["ok"], "false", path)
            XCTAssertEqual(result["eventName"], "error", path)
        }

        let invalidJson = broker.handle(action: "writeJson", path: "config/bad.json", text: "not-json", requestID: "bad-json")
        XCTAssertEqual(invalidJson["error"], "invalid-json")

        let oversized = broker.handle(
            action: "write",
            path: "notes/large.txt",
            text: String(repeating: "x", count: LocalFileBroker.maximumBytes + 1),
            requestID: "large"
        )
        XCTAssertEqual(oversized["error"], "file-too-large")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
