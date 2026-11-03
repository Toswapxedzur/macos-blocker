import Foundation
import VaultClassifierCore
import VaultClassifierResearch
import VaultClassifierBridge
#if canImport(AppKit)
import AppKit
#elseif os(Windows)
import WinSDK
#endif

@MainActor
extension VaultClassifierViewModel {
    func installChatGPT(directory: URL, coordinator: LocalClassifierCoordinator) {
        let limit = coordinator.snapshot().settings.maximumConcurrentTaggingRequests
        let apiKeys = APIKeyClassificationClient(profiles: { [weak coordinator] id in
            coordinator?.snapshot().workspaceCatalog.providerProfiles.first { $0.id == id }
        }, maximumConcurrentClassifications: limit)
        apiKeyClassificationClient = apiKeys
        coordinator.setCloudEngineResolver(apiKeys)
        do {
            let client = try ChatGPTAccountClient(directory: directory.appendingPathComponent("ChatGPT", isDirectory: true),
                dailyRequestLimit: coordinator.snapshot().settings.chatGPTDailyRequestLimit,
                taggingRetryPolicy: coordinator.snapshot().settings.chatGPTRetryPolicy,
                maximumConcurrentClassifications: limit) { [weak self] in
                Task { @MainActor [weak self] in await self?.refreshChatGPTStatus() }
            }
            chatGPTClient = client
            coordinator.setCloudEngineResolver(ClassificationConnectionResolver(subscription: client, apiKeys: apiKeys))
            Task { [weak self] in
                await self?.refreshChatGPTStatus()
                if await client.status().connected { try? await client.refreshModels() }
            }
        } catch { issue = error.localizedDescription }
    }

    func refreshChatGPTStatus() async {
        guard !isShuttingDown else { return }
        if let client = chatGPTClient { chatGPTStatus = await client.status() }
        apiKeyClassificationStatus = await apiKeyClassificationClient?.status()
        onWebStateChange?()
    }

    func connectChatGPT() {
        guard let client = chatGPTClient else { issue = "ChatGPT account service is unavailable."; return }
        Task { [weak self] in
            do {
                let url = try await client.beginSignIn()
                try Self.openChatGPTURL(url)
                await self?.refreshChatGPTStatus()
            } catch { self?.issue = error.localizedDescription; self?.onWebStateChange?() }
        }
    }

    static func openChatGPTURL(_ url: URL) throws {
        guard url.scheme == "https", ["auth.openai.com", "chatgpt.com"].contains(url.host ?? "") else { throw ChatGPTPlanError.invalidAuthorization }
        #if canImport(AppKit)
        guard NSWorkspace.shared.open(url) else { throw ChatGPTPlanError.invalidAuthorization }
        #elseif os(Windows)
        let address = Array(url.absoluteString.utf16) + [0]
        let verb = Array("open".utf16) + [0]
        let result = address.withUnsafeBufferPointer { value in verb.withUnsafeBufferPointer { verb in
            ShellExecuteW(nil, verb.baseAddress, value.baseAddress, nil, nil, SW_SHOWNORMAL)
        }}
        guard Int(bitPattern: result) > 32 else { throw ChatGPTPlanError.invalidAuthorization }
        #endif
    }

    func disconnectChatGPT() {
        guard let client = chatGPTClient else { return }
        Task { [weak self] in
            do { try await client.disconnect(); await self?.refreshChatGPTStatus() }
            catch { self?.issue = error.localizedDescription; self?.onWebStateChange?() }
        }
    }

    func refreshChatGPTModels() {
        guard let client = chatGPTClient else { return }
        Task { [weak self] in
            do {
                try await client.refreshModels()
                await self?.retryFailedClassifications(chatGPTOnly: true)
            }
            catch { self?.issue = error.localizedDescription }
            await self?.refreshChatGPTStatus()
        }
    }

    func saveClassificationProvider(typeID: String, providerModel: String, reasoningEffort: ClassificationReasoningEffort) throws {
        guard let coordinator else { throw CloudClassificationError.notConfigured }
        var catalog = coordinator.snapshot().workspaceCatalog
        guard let index = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }) else { throw CloudClassificationError.notConfigured }
        if providerModel.hasPrefix("chatgpt:") {
            let model = String(providerModel.dropFirst(8))
            guard chatGPTStatus.planUsageEnabled, chatGPTStatus.models.contains(where: { $0.identifier == model }) else { throw CloudClassificationError.notConfigured }
            try ClassificationModelPolicy.validate(provider: nil, model: model, effort: reasoningEffort)
            catalog.classifierTypes[index].classificationProvider = .chatGPT
            catalog.classifierTypes[index].chatGPT = .init(accountID: chatGPTStatus.accountID, model: model, reasoningEffort: reasoningEffort)
        } else if providerModel.hasPrefix("api:") {
            let parts = providerModel.dropFirst(4).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let profile = catalog.providerProfiles.first(where: { $0.id == parts[0] }),
                  APIKeyClassificationClient.supports(profile.type), profile.credential?.isEmpty == false,
                  providerModelCatalogs[profile.id]?.contains(where: { $0.id == parts[1] }) == true else { throw CloudClassificationError.notConfigured }
            try ClassificationModelPolicy.validate(provider: profile.type, model: parts[1], effort: reasoningEffort)
            catalog.classifierTypes[index].classificationProvider = .apiKey
            catalog.classifierTypes[index].apiKey = .init(profileID: profile.id, model: parts[1], reasoningEffort: reasoningEffort)
        } else { throw CloudClassificationError.notConfigured }
        catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
        try coordinator.updateWorkspaceCatalog(catalog)
        refreshLocalState(); issue = nil
    }

    func saveChatGPTUsageLimit(_ value: Int?) throws {
        guard value == nil || (1...100_000).contains(value!), let coordinator else { throw WebBridgeInputError.invalidChoice("daily request limit") }
        var settings = coordinator.snapshot().settings
        settings.chatGPTDailyRequestLimit = value
        try coordinator.updateSettings(settings)
        refreshLocalState(); issue = nil
        Task { await chatGPTClient?.setDailyRequestLimit(value) }
    }

    func saveChatGPTRetryPolicy(_ policy: TaggingRetryPolicy) throws {
        guard policy.isValid, let coordinator else { throw WebBridgeInputError.invalidChoice("tagging retry policy") }
        var settings = coordinator.snapshot().settings
        settings.chatGPTRetryPolicy = policy
        try coordinator.updateSettings(settings)
        refreshLocalState(); issue = nil
        Task { await chatGPTClient?.setTaggingRetryPolicy(policy) }
    }

    func retryChatGPTClassifications() {
        Task { [weak self] in
            await self?.retryFailedClassifications()
        }
    }

    /// Only a deliberate model-refresh (or the explicit Retry action) releases
    /// failed entries. A background account/status refresh never invokes this.
    func retryFailedClassifications(chatGPTOnly: Bool = false, profileID: String? = nil) async {
        guard !isShuttingDown, let coordinator else { return }
        if profileID == nil { await chatGPTClient?.retryFailedRequests() }
        if !chatGPTOnly { await apiKeyClassificationClient?.retryFailedRequests(profileID: profileID) }
        let types = coordinator.snapshot().workspaceCatalog.classifierTypes
        let matchingPlatforms = Set(types.filter { type in
            if chatGPTOnly { return type.classificationProvider == .chatGPT }
            if let profileID { return type.classificationProvider == .apiKey && type.apiKey.profileID == profileID }
            return true
        }.flatMap(\.applicablePlatformIDs))
        let matching = failedCloudClassifications.filter { matchingPlatforms.contains($0.value.platform) }
        for key in matching.keys { failedCloudClassifications.removeValue(forKey: key) }
        if !matching.isEmpty && !persistFailedClassifications() {
            for (key, value) in matching { failedCloudClassifications[key] = value }
            return
        }
        issue = nil
        // Also re-observe browser-side transport failures, which never reached
        // the native failure queue. This runs only after a user action.
        sharedHubClient?.broadcast(operation: SharedBrowserBridgeOperation.classifierStateUpdatedBroadcast,
            body: [:] as [String: String])
        for (platform, items) in Dictionary(grouping: matching.values, by: { $0.platform }) {
            broadcastRetryingVideoTags(platformID: platform, entryIDs: items.map { $0.item.entryID })
            queueVideoClassification(platformID: platform, items: items.map(\.item))
        }
        await refreshChatGPTStatus()
    }

}
