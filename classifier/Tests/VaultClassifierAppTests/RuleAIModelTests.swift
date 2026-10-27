import XCTest
import VaultClassifierCore
import VaultClassifierResearch
@testable import VaultClassifierApp

@MainActor
final class RuleAIModelTests: XCTestCase {
    func testRuleModelProjectionNeverExposesKeysAndValidatesModelEffort() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {LocalStateFile.flushAllPendingWrites();try? FileManager.default.removeItem(at:root)}
        let model=try VaultClassifierViewModel(headlessVaultDirectory:root)
        let coordinator=try XCTUnwrap(model.coordinator)
        var catalog=coordinator.snapshot().workspaceCatalog
        catalog.providerProfiles=[.init(id:"key",type:.openAI,credential:"PRIVATE-FIXTURE-KEY-SENTINEL")]
        try coordinator.updateWorkspaceCatalog(catalog);model.refreshLocalState()
        model.providerModelCatalogs=["key":[.init(identifier:"gpt-5"),.init(identifier:"gpt-4.1-mini"),.init(identifier:"embedding-fixture"),.init(identifier:"gpt-5-notools",supportsTools:false)]]
        let choices=model.ruleAIModels()
        XCTAssertEqual(choices.count,2)
        let json=String(decoding:try JSONSerialization.data(withJSONObject:choices),as:UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE-FIXTURE"));XCTAssertFalse(json.contains("credential"))
        XCTAssertTrue(model.validateRuleAI(.init(providerModel:"api:key:gpt-5",reasoningEffort:.low)))
        XCTAssertFalse(model.validateRuleAI(.init(providerModel:"api:key:gpt-4.1-mini",reasoningEffort:.low)))
        XCTAssertFalse(model.validateRuleAI(.init(providerModel:"api:other:gpt-5")))
        XCTAssertFalse(model.validateRuleAI(.init(providerModel:"chatgpt:gpt-5",accountID:"wrong-account")))
    }
}
