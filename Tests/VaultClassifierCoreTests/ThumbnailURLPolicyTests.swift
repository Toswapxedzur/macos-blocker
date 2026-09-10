import Foundation
import XCTest
@testable import VaultClassifierCore

final class ThumbnailURLPolicyTests: XCTestCase {
    func testAcceptsOnlyReviewedHttpsHostsPerPlatform() {
        XCTAssertTrue(ThumbnailURLPolicy.isAccepted(platformID: "bilibili", value: "https://i0.hdslb.com/bfs/archive/abc.jpg@672w_378h_1c.webp"))
        XCTAssertTrue(ThumbnailURLPolicy.isAccepted(platformID: "youtube", value: "https://i.ytimg.com/vi/abc/hqdefault.jpg"))
        XCTAssertFalse(ThumbnailURLPolicy.isAccepted(platformID: "bilibili", value: "http://i0.hdslb.com/bfs/archive/abc.jpg"), "https only")
        XCTAssertFalse(ThumbnailURLPolicy.isAccepted(platformID: "bilibili", value: "https://evil.example/hdslb.com/abc.jpg"))
        XCTAssertFalse(ThumbnailURLPolicy.isAccepted(platformID: "bilibili", value: "https://hdslb.com.evil/abc.jpg"))
        XCTAssertFalse(ThumbnailURLPolicy.isAccepted(platformID: "youtube", value: "https://i0.hdslb.com/abc.jpg"), "host must belong to the platform")
        XCTAssertFalse(ThumbnailURLPolicy.isAccepted(platformID: "bilibili", value: "https://user:pw@i0.hdslb.com/abc.jpg"))
        XCTAssertFalse(ThumbnailURLPolicy.isAccepted(platformID: "bilibili", value: "https://i0.hdslb.com/" + String(repeating: "a", count: 600)))
        XCTAssertFalse(ThumbnailURLPolicy.isAccepted(platformID: "tiktok", value: "https://p16-sign.tiktokcdn.com/x.jpg"), "unlisted platform never accepts")
    }

    func testResolvePrefersDerivedYouTubeThumbnailAndFallsBackToAcceptedCover() {
        XCTAssertEqual(
            ThumbnailURLPolicy.resolve(platformID: "youtube", entryID: "youtube:video:dQw4w9WgXcQ", provided: nil)?.absoluteString,
            "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
        )
        XCTAssertNil(ThumbnailURLPolicy.resolve(platformID: "youtube", entryID: "youtube:video:bad id!", provided: nil))
        XCTAssertEqual(
            ThumbnailURLPolicy.resolve(platformID: "bilibili", entryID: "bilibili:video:BV1xx", provided: "https://i2.hdslb.com/bfs/archive/c.jpg")?.absoluteString,
            "https://i2.hdslb.com/bfs/archive/c.jpg"
        )
        XCTAssertNil(ThumbnailURLPolicy.resolve(platformID: "bilibili", entryID: "bilibili:video:BV1xx", provided: nil))
        XCTAssertNil(ThumbnailURLPolicy.resolve(platformID: "bilibili", entryID: "bilibili:video:BV1xx", provided: "https://evil.example/c.jpg"))
        XCTAssertNil(ThumbnailURLPolicy.resolve(platformID: "reddit", entryID: "reddit:post:abc", provided: nil), "no derivable Reddit thumbnail")
    }

    func testVideoTagRequestsCarryABoundedThumbnailURL() throws {
        let json = Data("""
        {"platformID":"bilibili","items":[{"entryID":"bilibili:video:BV1","creatorID":"bilibili:creator:1","title":"t","thumbnailURL":"https://i0.hdslb.com/bfs/a.jpg"},{"entryID":"bilibili:video:BV2","creatorID":"bilibili:creator:1","title":"t","thumbnailURL":"https://evil.example/a.jpg"},{"entryID":"bilibili:video:BV3","creatorID":"bilibili:creator:1","title":"t"}]}
        """.utf8)
        let batch = try JSONDecoder().decode(NativeVideoTagsBatchRequest.self, from: json)
        XCTAssertNoThrow(try batch.validate())
        XCTAssertEqual(batch.items[0].acceptedThumbnailURL(platformID: "bilibili"), "https://i0.hdslb.com/bfs/a.jpg")
        XCTAssertNil(batch.items[1].acceptedThumbnailURL(platformID: "bilibili"), "untrusted host is dropped, not fatal")
        XCTAssertNil(batch.items[2].acceptedThumbnailURL(platformID: "bilibili"))
        let tooLong = NativeVideoTagsRequest(platformID: "bilibili", entryID: "bilibili:video:BV1", creatorID: "bilibili:creator:1", title: "t",
                                             thumbnailURL: "https://i0.hdslb.com/" + String(repeating: "b", count: 600))
        XCTAssertThrowsError(try tooLong.validate())
        // Round-trip keeps the field; an older peer without it still decodes.
        let single = NativeVideoTagsRequest(platformID: "youtube", entryID: "youtube:video:a", creatorID: "youtube:channel:c", title: "t")
        let decoded = try JSONDecoder().decode(NativeVideoTagsRequest.self, from: JSONEncoder().encode(single))
        XCTAssertNil(decoded.thumbnailURL)
    }

    func testRedditSupportsTheOnDeviceClassifier() {
        XCTAssertEqual(CollectionPlatformRegistry.definition(for: "reddit")?.supportsLocalModel, true)
        XCTAssertEqual(CollectionPlatformRegistry.definition(for: "bilibili")?.supportsLocalModel, true)
        XCTAssertEqual(CollectionPlatformRegistry.definition(for: "twitch")?.supportsLocalModel, false)
    }
}
