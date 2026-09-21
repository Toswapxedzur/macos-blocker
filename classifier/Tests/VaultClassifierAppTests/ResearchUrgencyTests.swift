import XCTest
@testable import VaultClassifierCore

/// Research urgency is DERIVED from the model's own tag confidences — the per-video
/// sample the creator accumulator averages (the only automatic research trigger).
final class ResearchUrgencyTests: XCTestCase {
    func testUrgencyIsInverseOfMeanConfidence() {
        XCTAssertEqual(ResearchUrgency.fromTagConfidences([5]), 1)   // certain → not urgent
        XCTAssertEqual(ResearchUrgency.fromTagConfidences([1]), 5)   // guess → urgent
        XCTAssertEqual(ResearchUrgency.fromTagConfidences([3]), 3)
        XCTAssertEqual(ResearchUrgency.fromTagConfidences([5, 3]), 2) // mean 4 → 6-4=2
    }

    func testDeclineIsMaximallyUrgent() {
        XCTAssertEqual(ResearchUrgency.fromTagConfidences([]), 5)     // no tags = couldn't place it
    }
}
