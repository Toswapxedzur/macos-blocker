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

    func testCuratedCatalogContainsOnlyValidatedQ4KMGGUFURLs() throws {
        XCTAssertEqual(LocalModelCatalog.curated.count, 8)
        XCTAssertGreaterThanOrEqual(Set(LocalModelCatalog.curated.map(\.family)).count, 5)
        XCTAssertEqual(Set(LocalModelCatalog.curated.map(\.id)).count, LocalModelCatalog.curated.count)
        XCTAssertEqual(Set(LocalModelCatalog.curated.map(\.ggufFileName)).count, LocalModelCatalog.curated.count)

        for entry in LocalModelCatalog.curated {
            let url = try entry.downloadURL
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "huggingface.co")
            XCTAssertEqual(
                url.absoluteString,
                "https://huggingface.co/\(entry.repo)/resolve/main/\(entry.ggufFileName)"
            )
            XCTAssertTrue(entry.ggufFileName.hasSuffix("Q4_K_M.gguf"))
            XCTAssertGreaterThan(entry.downloadSizeBytes, 0)
            XCTAssertGreaterThan(entry.minimumRAMGB, 0)
        }
    }

    func testDownloadURLValidationRejectsTraversalAndAlternateRoutes() {
        let invalidRepositories = [
            "bartowski/../private",
            "https://example.com/model",
            "bartowski%2Fother/model",
            "bartowski/model/extra",
            "/bartowski/model",
        ]
        for repo in invalidRepositories {
            XCTAssertThrowsError(
                try LocalModelCatalog.validatedDownloadURL(repo: repo, ggufFileName: "safe-Q4_K_M.gguf")
            )
        }

        let invalidFileNames = [
            "../model.gguf",
            "folder/model.gguf",
            "folder\\model.gguf",
            "%2e%2e%2fmodel.gguf",
            "model.bin",
        ]
        for fileName in invalidFileNames {
            XCTAssertThrowsError(
                try LocalModelCatalog.validatedDownloadURL(
                    repo: "bartowski/Safe-GGUF",
                    ggufFileName: fileName
                )
            )
        }
    }

    func testRecommendedScalesWithRAM() {
        let low = LocalModelCatalog.recommended(systemRAMGB: 8)
        let mid = LocalModelCatalog.recommended(systemRAMGB: 16)
        let high = LocalModelCatalog.recommended(systemRAMGB: 32)
        XCTAssertNotNil(low)
        XCTAssertNotNil(mid)
        XCTAssertNotNil(high)
        XCTAssertLessThanOrEqual(low!.paramsB, mid!.paramsB)
        XCTAssertLessThanOrEqual(mid!.paramsB, high!.paramsB)
        XCTAssertLessThan(low!.paramsB, 2.0)
        XCTAssertGreaterThan(high!.paramsB, 7.0)
        XCTAssertLessThanOrEqual(mid!.minimumRAMGB, 16)
        // Requirement: a 16 GB Mac is recommended Qwen2.5-7B (verified to run there).
        XCTAssertEqual(mid?.id, "qwen2.5-7b-instruct-q4-k-m")
    }

    func testUnderpoweredMachineStillGetsSmallestRAMClass() {
        let entry = LocalModelCatalog.recommended(systemRAMGB: 4)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.minimumRAMGB, LocalModelCatalog.curated.map(\.minimumRAMGB).min())
    }

    func testEntryLookupAndCatalogCodable() throws {
        let entry = try XCTUnwrap(LocalModelCatalog.entry(id: "llama-3.2-3b-instruct-q4-k-m"))
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LocalModelCatalogEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    func testPhysicalRAMIsPositive() {
        XCTAssertGreaterThan(HardwareProfile.physicalRAMGB(), 0)
    }
}
