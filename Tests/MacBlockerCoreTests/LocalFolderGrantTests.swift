import XCTest
@testable import MacBlockerCore

final class LocalFolderGrantTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LocalFolderGrant.clear()
    }

    override func tearDown() {
        LocalFolderGrant.clear()
        super.tearDown()
    }

    func testStartsDisconnected() {
        XCTAssertFalse(LocalFolderGrant.isConnected)
        XCTAssertNil(LocalFolderGrant.resolvedFolderURL())
        XCTAssertEqual(LocalFolderGrant.folderName, "")
    }

    func testStoreResolveAndClearRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-grant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bookmark = try dir.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        LocalFolderGrant.store(bookmark: bookmark)

        XCTAssertTrue(LocalFolderGrant.isConnected)
        let resolved = try XCTUnwrap(LocalFolderGrant.resolvedFolderURL())
        XCTAssertEqual(resolved.standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertEqual(LocalFolderGrant.folderName, dir.lastPathComponent)

        LocalFolderGrant.clear()
        XCTAssertFalse(LocalFolderGrant.isConnected)
        XCTAssertNil(LocalFolderGrant.resolvedFolderURL())
    }
}
