import XCTest
@testable import VaultClassifierCore

final class LocalModelCatalogTests: XCTestCase {
    func testCuratedCatalogContainsOnlyValidatedQ4KMGGUFURLs() throws {
        XCTAssertEqual(LocalModelCatalog.curated.count, 3, "one Qwen2.5 tier per Speed↔Quality position")
        XCTAssertEqual(LocalModelCatalog.curated.map(\.tier), [.fast, .balanced, .best])
        XCTAssertEqual(Set(LocalModelCatalog.curated.map(\.family)), ["Qwen"])
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
        XCTAssertEqual(LocalModelCatalog.recommended(systemRAMGB: 8)?.tier, .fast)
        // Requirement: a 16 GB Mac is recommended Qwen2.5-7B (verified to run there).
        XCTAssertEqual(LocalModelCatalog.recommended(systemRAMGB: 16)?.id, "qwen2.5-7b-instruct-q4-k-m")
        XCTAssertEqual(LocalModelCatalog.recommended(systemRAMGB: 32)?.tier, .best)
    }

    func testUnderpoweredMachineStillGetsSmallestRAMClass() {
        let entry = LocalModelCatalog.recommended(systemRAMGB: 4)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.minimumRAMGB, LocalModelCatalog.curated.map(\.minimumRAMGB).min())
    }

    func testEntryLookupAndCatalogCodable() throws {
        let entry = try XCTUnwrap(LocalModelCatalog.entry(id: "qwen2.5-3b-instruct-q4-k-m"))
        XCTAssertEqual(LocalModelCatalog.entry(for: .fast), entry)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LocalModelCatalogEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    func testPhysicalRAMIsPositive() {
        XCTAssertGreaterThan(HardwareProfile.physicalRAMGB(), 0)
    }
}
