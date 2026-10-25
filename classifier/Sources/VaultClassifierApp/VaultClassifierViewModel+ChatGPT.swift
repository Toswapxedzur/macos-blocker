import Foundation
import VaultClassifierCore
import VaultClassifierResearch
import VaultClassifierBridge
import VaultClassifierLLM
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
            coordinator.setCloudEngineResolver(client)
            Task { [weak self] in
                await self?.refreshChatGPTStatus()
                if await client.status().connected { try? await client.refreshModels() }
            }
        } catch { issue = error.localizedDescription }
    }

    func refreshChatGPTStatus() async {
        guard let client = chatGPTClient, !isShuttingDown else { return }
        chatGPTStatus = await client.status()
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
        if providerModel == "local" {
            catalog.classifierTypes[index].classificationProvider = .local
        } else if providerModel.hasPrefix("chatgpt:") {
            let model = String(providerModel.dropFirst(8))
            guard chatGPTStatus.planUsageEnabled, chatGPTStatus.models.contains(where: { $0.identifier == model }) else { throw CloudClassificationError.notConfigured }
            catalog.classifierTypes[index].classificationProvider = .chatGPT
            catalog.classifierTypes[index].chatGPT = .init(accountID: chatGPTStatus.accountID, model: model, searchEnabled: searchEnabled)
        } else { throw CloudClassificationError.notConfigured }
        catalog.classifierTypes[index].chatGPT.searchEnabled = searchEnabled
        catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
        try coordinator.updateWorkspaceCatalog(catalog)
        refreshLocalState(); reconcileLocalRuntime(); issue = nil
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

    func reconcileLocalRuntime() {
        guard liveEngineRuntime, !isShuttingDown else { return }
        let needsLocal = coordinator?.snapshot().workspaceCatalog.classifierTypes.contains { $0.classificationProvider == .local && !$0.isPaused } == true
        if needsLocal {
            if localLLMRegistry == nil, let coordinator { installLocalLLMEngine(coordinator: coordinator) }
        } else {
            let warmup = modelWarmupTask
            warmup?.cancel(); modelWarmupTask = nil
            let registry = localLLMRegistry
            activeLocalRuntimeID = nil
            localLLMRegistry = nil; coordinator?.setOnDeviceLLMEngineResolver(nil)
            if registry != nil || warmup != nil {
                let id = UUID()
                retiringLocalModels[id] = Task { [weak self] in
                    await registry?.shutdown(); await warmup?.value
                    self?.retiringLocalModels[id] = nil
                }
            }
        }
    }
}
