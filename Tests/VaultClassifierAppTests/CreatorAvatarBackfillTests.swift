import Foundation
import XCTest
@testable import VaultClassifierApp

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
}
