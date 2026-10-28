import XCTest
@testable import VaultClassifierCore

final class TaggingSettingsTests: XCTestCase {
    func testDefaultAndAllEvidenceLevelsRoundTrip() throws {
        XCTAssertEqual(TaggingSettings().minimumConfidence, 4)
        for level in 1...5 {
            let settings = TaggingSettings(minimumConfidence: level, houseRules: "Keep my vocabulary")
            XCTAssertEqual(try JSONDecoder().decode(TaggingSettings.self, from: JSONEncoder().encode(settings)), settings)
        }
    }

    func testRetiredTagControlsResetToFourWithoutLosingInstructions() throws {
        for oldPosition in 1...5 {
            let json = "{\"strictness\":\(oldPosition),\"minimumTagsOverride\":1,\"maximumTagsOverride\":2,\"houseRules\":\"Keep my vocabulary\"}"
            let settings = try JSONDecoder().decode(TaggingSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.minimumConfidence, 4)
            XCTAssertEqual(settings.houseRules, "Keep my vocabulary")
            let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
            XCTAssertFalse(encoded.contains("strictness"))
            XCTAssertFalse(encoded.contains("TagsOverride"))
        }
    }

    func testInvalidEvidenceLevelsUseTheDefault() throws {
        for json in [#"{"minimumConfidence":0}"#, #"{"minimumConfidence":6}"#,
                     #"{"minimumConfidence":1.5}"#, #"{"minimumConfidence":true}"#,
                     #"{"minimumConfidence":"high"}"#] {
            XCTAssertEqual(try JSONDecoder().decode(TaggingSettings.self, from: Data(json.utf8)).minimumConfidence, 4)
        }
    }
}
