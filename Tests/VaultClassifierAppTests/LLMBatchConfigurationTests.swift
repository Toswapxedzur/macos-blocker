import XCTest
@testable import VaultClassifierApp
import VaultClassifierCore

@MainActor
final class LLMBatchConfigurationTests: XCTestCase {
    func testDatasetRevisionAdvanceDoesNotStopItsOwnLLMBatch() {
        let configuration = LLMAssistConfiguration(
            providerProfileID: "provider",
            modelIdentifier: "model"
        )
        let expected = ClassifierTypeAsset(
            id: "type",
            name: "Classifier",
            treeID: "tree",
            treeRevision: 1,
            datasetID: "dataset",
            datasetRevision: 5,
            applicablePlatformID: "youtube",
            llmAssistConfiguration: configuration,
            updatedAtMilliseconds: 100
        )
        var reconciledAfterSavedDecision = expected
        reconciledAfterSavedDecision.datasetRevision = 6
        XCTAssertTrue(
            VaultClassifierViewModel.llmBatchConfigurationIsUnchanged(
                expected: expected,
                current: reconciledAfterSavedDecision
            )
        )

        var changedConfiguration = reconciledAfterSavedDecision
        changedConfiguration.llmAssistConfiguration?.maximumTagCount = 1
        XCTAssertFalse(
            VaultClassifierViewModel.llmBatchConfigurationIsUnchanged(
                expected: expected,
                current: changedConfiguration
            )
        )
    }
}
