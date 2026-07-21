import Foundation
import XCTest
@testable import VaultClassifierApp
@testable import VaultClassifierCore

final class CreatorAvatarBackfillTests: XCTestCase {
    func testWebViewContentSecurityPolicyPermitsCachedCreatorAvatarScheme() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let indexURL = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/VaultClassifierApp/WebAssets/index.html")
        let index = try String(contentsOf: indexURL, encoding: .utf8)

        XCTAssertTrue(index.contains("img-src 'self' data: vaultclassifieravatar:"))
    }

    func testBackfillExtractsAnApprovedOpenGraphAvatar() throws {
        let html = """
        <html><head>
          <meta content="https://yt3.googleusercontent.com/channel-avatar=s900-c-k" property="og:image">
        </head></html>
        """

        let avatarURL = CreatorAvatarBackfill.avatarURL(
            in: html,
            creatorPageURL: try XCTUnwrap(URL(string: "https://www.youtube.com/channel/UC123")),
            platformID: "youtube"
        )

        XCTAssertEqual(avatarURL, "https://yt3.googleusercontent.com/channel-avatar=s900-c-k")
    }

    func testBackfillRejectsAnUnapprovedOpenGraphImage() throws {
        let html = "<meta property=\"og:image\" content=\"https://images.example.invalid/avatar.png\">"

        XCTAssertNil(CreatorAvatarBackfill.avatarURL(
            in: html,
            creatorPageURL: try XCTUnwrap(URL(string: "https://www.youtube.com/channel/UC123")),
            platformID: "youtube"
        ))
    }

    func testFallbackCandidatesIncludeCreatorsWithoutAPublicPageOnlyWhenEnabled() {
        let entry = CollectedPlatformEntry(
            id: "entry",
            platformID: "youtube",
            entryID: "video",
            creatorID: "UC123",
            creatorName: "Creator",
            entryType: "video",
            title: "Video"
        )

        XCTAssertTrue(CreatorAvatarBackfill.candidates(
            entries: [entry],
            allowedPlatformIDs: ["youtube"]
        ).isEmpty)
        XCTAssertEqual(CreatorAvatarBackfill.candidates(
            entries: [entry],
            allowedPlatformIDs: ["youtube"],
            includeUnavailableCreatorPages: true
        ).count, 1)
    }

    func testPublicCreatorPageBeatsFallbackCandidateFromANewerIncompleteEntry() {
        let olderPageEntry = CollectedPlatformEntry(
            id: "older",
            platformID: "youtube",
            entryID: "video-one",
            creatorID: "UC123",
            creatorName: "Creator",
            entryType: "video",
            title: "Video one",
            attributes: ["creatorURL": "https://www.youtube.com/@creator"],
            lastObservedAtMilliseconds: 1
        )
        let newerIncompleteEntry = CollectedPlatformEntry(
            id: "newer",
            platformID: "youtube",
            entryID: "video-two",
            creatorID: "UC123",
            creatorName: "Creator",
            entryType: "video",
            title: "Video two",
            lastObservedAtMilliseconds: 2
        )

        let candidates = CreatorAvatarBackfill.candidates(
            entries: [newerIncompleteEntry, olderPageEntry],
            allowedPlatformIDs: ["youtube"],
            includeUnavailableCreatorPages: true
        )

        XCTAssertEqual(candidates.count, 1)
        guard case .creatorPageURL(let pageURL) = candidates[0].source else {
            return XCTFail("Expected the public creator page to be fetched before API fallback.")
        }
        XCTAssertEqual(pageURL, "https://www.youtube.com/@creator")
    }
}
