import XCTest
@testable import VaultClassifierCore

final class CreatorReferenceTests: XCTestCase {
    func testLinksAndHandlesResolveToTheCollectorsCreatorIDs() {
        func id(_ platform: String, _ input: String) -> String? { CreatorReference.creatorID(platformID: platform, input: input, known: []) }
        XCTAssertEqual(id("youtube", "https://www.youtube.com/@DWNews/videos"), "youtube:handle:@dwnews")
        XCTAssertEqual(id("youtube", "@dwnews"), "youtube:handle:@dwnews")
        XCTAssertEqual(id("youtube", "https://www.youtube.com/channel/UCknLrEdhRCp1aegoMqRaCZg"), "youtube:channel:UCknLrEdhRCp1aegoMqRaCZg")
        XCTAssertEqual(id("bilibili", "https://space.bilibili.com/12345?spm_id_from=1"), "bilibili:creator:space:12345")
        XCTAssertEqual(id("reddit", "https://www.reddit.com/r/Brawlstars/"), "reddit:subreddit:brawlstars")
        XCTAssertEqual(id("reddit", "r/brawlstars"), "reddit:subreddit:brawlstars")
        XCTAssertEqual(id("twitter", "https://x.com/ClashReport"), "twitter:account:clashreport")
        XCTAssertEqual(id("twitter", "@ClashReport"), "twitter:account:clashreport")
        XCTAssertNil(id("youtube", "DW News"), "a name not seen yet is not guessed")
    }

    func testANameAlreadySeenResolvesToItsCreator() {
        let seen = CollectedPlatformEntry(id: "e", platformID: "youtube", entryID: "youtube:video:a", creatorID: "youtube:handle:@dwnews", creatorName: "DW News", entryType: "video", title: "A")
        XCTAssertEqual(CreatorReference.creatorID(platformID: "youtube", input: "dw news", known: [seen]), "youtube:handle:@dwnews")
        XCTAssertNil(CreatorReference.creatorID(platformID: "reddit", input: "DW News", known: [seen]), "only on its own platform")
    }

    func testFallbackNames() {
        XCTAssertEqual(CreatorReference.fallbackName(of: "youtube:handle:@dwnews"), "@dwnews")
        XCTAssertEqual(CreatorReference.fallbackName(of: "reddit:subreddit:brawlstars"), "r/brawlstars")
        XCTAssertEqual(CreatorReference.fallbackName(of: "twitter:account:clashreport"), "@clashreport")
        XCTAssertEqual(CreatorReference.platformID(of: "bilibili:creator:space:1"), "bilibili")
    }
}
