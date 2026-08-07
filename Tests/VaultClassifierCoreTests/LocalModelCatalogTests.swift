import XCTest
@testable import VaultClassifierCore

final class LocalModelCatalogTests: XCTestCase {

    func testLatencyBandBoundaries() {
        XCTAssertEqual(LatencyBand.classify(medianMilliseconds: 120), .green)
        XCTAssertEqual(LatencyBand.classify(medianMilliseconds: 499), .green)
        XCTAssertEqual(LatencyBand.classify(medianMilliseconds: 500), .danger)
        XCTAssertEqual(LatencyBand.classify(medianMilliseconds: 1_000), .danger)
        XCTAssertEqual(LatencyBand.classify(medianMilliseconds: 1_001), .reject)
    }

    func testAllCuratedEntriesMeetCapabilityGates() {
        XCTAssertFalse(LocalModelCatalog.curated.isEmpty)
        XCTAssertEqual(LocalModelCatalog.eligible.count, LocalModelCatalog.curated.count,
                       "curated list should only contain capability-passing models")
    }

    func testRecommendedScalesWithRAM() {
        let low = LocalModelCatalog.recommended(systemRAMGB: 8)
        let mid = LocalModelCatalog.recommended(systemRAMGB: 16)
        let high = LocalModelCatalog.recommended(systemRAMGB: 32)
        XCTAssertNotNil(low)
        XCTAssertNotNil(mid)
        XCTAssertNotNil(high)
        // More RAM never recommends a smaller model.
        XCTAssertLessThanOrEqual(low!.parameterBillions, mid!.parameterBillions)
        XCTAssertLessThanOrEqual(mid!.parameterBillions, high!.parameterBillions)
        // 8 GB machine gets a ~1–1.5B model; 24 GB+ unlocks the 7B.
        XCTAssertLessThan(low!.parameterBillions, 2.0)
        XCTAssertGreaterThan(high!.parameterBillions, 3.5)
    }

    func testRecommendedNeverExceedsRAMFloorWhenAvoidable() {
        let mid = LocalModelCatalog.recommended(systemRAMGB: 16)
        XCTAssertLessThanOrEqual(mid!.minimumRAMGB, 16)
    }

    func testUnderpoweredMachineStillGetsSmallestModel() {
        let entry = LocalModelCatalog.recommended(systemRAMGB: 4) // below every floor
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.minimumRAMGB, LocalModelCatalog.eligible.map(\.minimumRAMGB).min())
    }

    func testEntryLookupAndCatalogCodable() throws {
        let entry = try XCTUnwrap(LocalModelCatalog.entry(id: "mlx-community/Llama-3.2-3B-Instruct-4bit"))
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LocalModelCatalogEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    func testPhysicalRAMIsPositive() {
        XCTAssertGreaterThan(HardwareProfile.physicalRAMGB(), 0)
    }
}
