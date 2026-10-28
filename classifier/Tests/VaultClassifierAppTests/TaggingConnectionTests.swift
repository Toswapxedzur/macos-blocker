import XCTest
@testable import VaultClassifierApp
import VaultClassifierCore

@MainActor
final class TaggingConnectionTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("single-tagging-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        LocalStateFile.flushAllPendingWrites()
        try? FileManager.default.removeItem(at: directory)
    }
    private func model() throws -> VaultClassifierViewModel {
        try VaultClassifierViewModel(headlessVaultDirectory: directory)
    }
    func testCreateEditClearAndRestartKeepOneStableConnectionPerProvider() throws {
        let vm = try model()
        for provider in ["openAI", "gemini", "xAI"] {
            _ = vm.performWebAction("saveTaggingConnection", data: ["type": provider, "credential": ""])
            XCTAssertFalse(vm.localState!.workspaceCatalog.providerProfiles.contains { $0.type.rawValue == provider })
            _ = vm.performWebAction("saveTaggingConnection", data: ["type": provider, "credential": " fixture-first "])
            XCTAssertNil(vm.issue)
            let profile = try XCTUnwrap(vm.localState!.workspaceCatalog.providerProfiles.first { $0.type.rawValue == provider })
            XCTAssertEqual(profile.credential, "fixture-first")
            _ = vm.performWebAction("createProviderProfile", data: ["type": provider])
            _ = vm.performWebAction("saveTaggingConnection", data: ["type": provider, "credential": "fixture-second"])
            let matches = vm.localState!.workspaceCatalog.providerProfiles.filter { $0.type.rawValue == provider }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?.id, profile.id)
            XCTAssertEqual(matches.first?.credential, "fixture-second")
            _ = vm.performWebAction("saveTaggingConnection", data: ["type": provider, "credential": " "])
            XCTAssertNil(vm.issue)
            XCTAssertEqual(vm.localState!.workspaceCatalog.providerProfiles.first { $0.id == profile.id }?.credential, nil)
        }
        LocalStateFile.flushAllPendingWrites()
        XCTAssertEqual(try model().localState?.workspaceCatalog.providerProfiles, vm.localState?.workspaceCatalog.providerProfiles)
    }
    func testExistingConnectionKeepsItsIDAndGroupModelReferences() throws {
        let vm = try model(), coordinator = try XCTUnwrap(vm.coordinator)
        _ = vm.performWebAction("createClassifierType", data: ["name": "Video topics", "platformIDs": ["youtube"]])
        var catalog = coordinator.snapshot().workspaceCatalog
        var profile = APIKeyProviderProfile(type: .openAI)
        profile.name = "My saved OpenAI connection"
        profile.testModelIdentifier = "saved-model"
        profile.credential = "fixture-old"
        try profile.validate()
        catalog.providerProfiles = [profile]
        catalog.classifierTypes[0].classificationProvider = .apiKey
        catalog.classifierTypes[0].apiKey = .init(profileID: profile.id, model: "saved-model")
        let selection = catalog.classifierTypes[0].apiKey
        try coordinator.updateWorkspaceCatalog(catalog)
        vm.refreshLocalState()
        _ = vm.performWebAction("saveTaggingConnection", data: ["type": "openAI", "credential": "fixture-new"])
        let saved = try XCTUnwrap(vm.localState?.workspaceCatalog.providerProfiles.first)
        XCTAssertEqual(saved.id, profile.id)
        XCTAssertEqual(saved.name, profile.name)
        XCTAssertEqual(vm.localState?.workspaceCatalog.classifierTypes.first?.apiKey, selection)
        XCTAssertEqual(saved.testModelIdentifier, profile.testModelIdentifier)
        XCTAssertEqual(saved.credential, "fixture-new")
    }
    func testInvalidOrAmbiguousWritesPreserveAllSavedKeys() throws {
        let vm = try model(), coordinator = try XCTUnwrap(vm.coordinator)
        var catalog = coordinator.snapshot().workspaceCatalog
        var first = APIKeyProviderProfile(type: .gemini); first.credential = "fixture-first"
        var second = APIKeyProviderProfile(type: .gemini); second.credential = "fixture-second"
        catalog.providerProfiles = [first, second]
        try coordinator.updateWorkspaceCatalog(catalog)
        vm.refreshLocalState()
        for data: [String: Any] in [
            ["type": "gemini", "credential": "replacement"],
            ["type": "anthropic", "credential": "replacement"],
            ["type": "openAI", "credential": String(repeating: "a", count: ProviderCredentialRecord.maximumCharacters + 1)],
            ["type": "openAI"]
        ] {
            _ = vm.performWebAction("saveTaggingConnection", data: data)
            XCTAssertNotNil(vm.issue)
            XCTAssertEqual(vm.localState?.workspaceCatalog.providerProfiles, [first, second])
        }
    }
    func testRetryPoliciesPersistSeparatelyForEachConnection() throws {
        let vm = try model()
        _ = vm.performWebAction("saveChatGPTRetryPolicy", data: ["retryIntervalSeconds": "90", "retryMaximumAttempts": "2"])
        XCTAssertNil(vm.issue)
        _ = vm.performWebAction("saveTaggingRetryPolicy", data: ["type": "gemini", "retryIntervalSeconds": "120", "retryMaximumAttempts": "4"])
        XCTAssertNil(vm.issue)
        let state = try XCTUnwrap(vm.localState)
        XCTAssertEqual(state.settings.chatGPTRetryPolicy, .init(intervalSeconds: 90, maximumAttempts: 2))
        XCTAssertEqual(state.workspaceCatalog.providerProfiles.first { $0.type == .gemini }?.taggingRetryPolicy,
            .init(intervalSeconds: 120, maximumAttempts: 4))
        XCTAssertNil(state.workspaceCatalog.providerProfiles.first { $0.type == .openAI })
        LocalStateFile.flushAllPendingWrites()
        let reloaded = try model()
        XCTAssertEqual(reloaded.localState?.settings.chatGPTRetryPolicy, state.settings.chatGPTRetryPolicy)
        XCTAssertEqual(reloaded.localState?.workspaceCatalog.providerProfiles.first?.taggingRetryPolicy,
            .init(intervalSeconds: 120, maximumAttempts: 4))
    }
    func testInvalidRetryPolicyDoesNotChangeConnections() throws {
        let vm = try model()
        let before = try XCTUnwrap(vm.localState)
        _ = vm.performWebAction("saveTaggingRetryPolicy", data: ["type": "gemini", "retryIntervalSeconds": "0", "retryMaximumAttempts": "3"])
        XCTAssertNotNil(vm.issue)
        XCTAssertEqual(vm.localState?.workspaceCatalog.providerProfiles, before.workspaceCatalog.providerProfiles)
        _ = vm.performWebAction("saveChatGPTRetryPolicy", data: ["retryIntervalSeconds": "60", "retryMaximumAttempts": "11"])
        XCTAssertNotNil(vm.issue)
        XCTAssertEqual(vm.localState?.settings.chatGPTRetryPolicy, before.settings.chatGPTRetryPolicy)
    }
}
