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
        do {
            let client = try ChatGPTAccountClient(directory: directory.appendingPathComponent("ChatGPT", isDirectory: true),
                dailyRequestLimit: coordinator.snapshot().settings.chatGPTDailyRequestLimit) { [weak self] in
                Task { @MainActor [weak self] in await self?.refreshChatGPTStatus() }
            }
            chatGPTClient = client
            let apiKeys = APIKeyClassificationClient(profiles: { [weak coordinator] id in
                coordinator?.snapshot().workspaceCatalog.providerProfiles.first { $0.id == id }
            })
            apiKeyClassificationClient = apiKeys
            coordinator.setCloudEngineResolver(ClassificationConnectionResolver(subscription: client, apiKeys: apiKeys))
            Task { [weak self] in
                await self?.refreshChatGPTStatus()
                if await client.status().connected { try? await client.refreshModels() }
            }
        } catch { issue = error.localizedDescription }
    }

    func refreshChatGPTStatus() async {
        guard let client = chatGPTClient, !isShuttingDown else { return }
        chatGPTStatus = await client.status()
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
            do { try await client.refreshModels() }
            catch { self?.issue = error.localizedDescription }
            await self?.refreshChatGPTStatus()
        }
    }

    func saveClassificationProvider(typeID: String, providerModel: String, searchEnabled: Bool) throws {
        guard let coordinator else { throw CloudClassificationError.notConfigured }
        var catalog = coordinator.snapshot().workspaceCatalog
        guard let index = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }) else { throw CloudClassificationError.notConfigured }
        if providerModel.hasPrefix("chatgpt:") {
            let model = String(providerModel.dropFirst(8))
            guard chatGPTStatus.planUsageEnabled, chatGPTStatus.models.contains(where: { $0.identifier == model }) else { throw CloudClassificationError.notConfigured }
            catalog.classifierTypes[index].classificationProvider = .chatGPT
            catalog.classifierTypes[index].chatGPT = .init(accountID: chatGPTStatus.accountID, model: model, searchEnabled: searchEnabled)
        } else if providerModel.hasPrefix("api:") {
            let parts = providerModel.dropFirst(4).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let profile = catalog.providerProfiles.first(where: { $0.id == parts[0] }),
                  APIKeyClassificationClient.supports(profile.type), profile.credential?.isEmpty == false,
                  providerModelCatalogs[profile.id]?.contains(where: { $0.id == parts[1] }) == true else { throw CloudClassificationError.notConfigured }
            if profile.type == .gemini && searchEnabled && !(parts[1].hasPrefix("gemini-3") || parts[1].hasPrefix("gemini-4")) { throw CloudClassificationError.searchUnavailable }
            catalog.classifierTypes[index].classificationProvider = .apiKey
            catalog.classifierTypes[index].apiKey = .init(profileID: profile.id, model: parts[1], searchEnabled: searchEnabled)
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

    func retryChatGPTClassifications() {
        guard let client = chatGPTClient else { return }
        Task { [weak self] in
            await client.retryFailedRequests()
            await self?.apiKeyClassificationClient?.retryFailedRequests()
            guard let self, !self.isShuttingDown else { return }
            let failed = self.failedCloudClassifications
            self.failedCloudClassifications.removeAll(); self.issue = nil
            for (platform, items) in Dictionary(grouping: failed.values, by: { $0.platform }) {
                for row in items { self.inFlightVideoClassifications.insert(Self.inFlightKey(platform, row.item.entryID)) }
                self.classificationCoalescer.enqueue(platformID: platform, items: items.map(\.item))
            }
            await self.refreshChatGPTStatus()
        }
    }

}
