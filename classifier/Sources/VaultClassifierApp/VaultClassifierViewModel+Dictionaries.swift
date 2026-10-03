import Foundation
import VaultClassifierCore

@MainActor
extension VaultClassifierViewModel {
    func installDictionaries(directory: URL, coordinator: LocalClassifierCoordinator, automaticallyCheck: Bool) throws {
        let disk = try DictionaryDiskStore(root: directory.appendingPathComponent("dictionaries", isDirectory: true), settings: coordinator.snapshot().settings.dictionaries)
        let service = OfficialDictionaryService(disk: disk)
        dictionaryService = service; coordinator.setDictionaryProvider(service)
        Task { [weak self] in
            guard let self else { return }
            self.dictionaryStatus = await service.status()
            self.onWebStateChange?()
            if automaticallyCheck { self.checkDictionaryUpdates() }
        }
    }
    func saveDictionarySettings(mode: String, cacheSize: Int, contributionEnabled: Bool, choiceMade: Bool) throws {
        guard let mode = CreatorDictionaryMode(rawValue: mode), (1...100_000).contains(cacheSize), let coordinator else { throw DictionaryError.invalidPack }
        var settings = coordinator.snapshot().settings
        settings.dictionaries.creatorMode = mode; settings.dictionaries.creatorCacheSize = cacheSize
        settings.dictionaries.contributionEnabled = contributionEnabled
        if choiceMade { settings.dictionaries.contributionChoiceMade = true }
        // Immediate synchronous gate: disabling does not wait behind a network operation.
        if !contributionEnabled { try dictionaryService?.disk.configure(settings.dictionaries) }
        try coordinator.updateSettings(settings)
        // Enabling follows the successful durable settings write; disabling
        // closes the upload gate immediately, even if persistence fails.
        try dictionaryService?.disk.configure(settings.dictionaries)
        refreshLocalState()
        if let service = dictionaryService {
            let dictionaries = settings.dictionaries
            Task { [weak self] in
                do { try await service.configure(self?.coordinator?.snapshot().settings.dictionaries ?? dictionaries); self?.dictionaryStatus = await service.status() }
                catch { self?.dictionaryNotice = error.localizedDescription }
                self?.onWebStateChange?()
            }
        }
    }
    func completeDictionaryOnboarding(enabled: Bool) {
        guard let d = coordinator?.snapshot().settings.dictionaries else { return }
        do { try saveDictionarySettings(mode: d.creatorMode.rawValue, cacheSize: d.creatorCacheSize, contributionEnabled: enabled, choiceMade: true) }
        catch { issue = error.localizedDescription }
        onWebStateChange?()
    }
    func checkDictionaryUpdates() {
        guard let service = dictionaryService, !dictionaryBusy else { return }
        dictionaryBusy = true; dictionaryNotice = nil
        Task { [weak self] in
            do { self?.dictionaryStatus = try await service.checkUpdates() }
            catch { self?.dictionaryNotice = error.localizedDescription }
            self?.dictionaryBusy = false; self?.onWebStateChange?()
        }
    }
    func downloadDictionary(kind: String) throws {
        guard let kind = KnowledgeEntryKind(rawValue: kind), let service = dictionaryService else { throw DictionaryError.invalidPack }
        guard !dictionaryBusy else { return }
        dictionaryBusy = true; dictionaryNotice = nil
        Task { [weak self] in
            do { self?.dictionaryStatus = try await service.update(kind); self?.dictionaryNotice = "Dictionary updated. Personal definitions are preserved." }
            catch { self?.dictionaryNotice = error.localizedDescription }
            self?.dictionaryBusy = false; self?.onWebStateChange?()
        }
    }
    func dictionaryPayload(_ settings: DictionarySettings) -> [String: Any] {
        var payload = dictionaryStatus
        payload["creatorMode"] = settings.creatorMode.rawValue
        payload["creatorCacheSize"] = settings.creatorCacheSize
        payload["contributionEnabled"] = settings.contributionEnabled
        payload["contributionChoiceMade"] = settings.contributionChoiceMade
        payload["nativePrompt"] = contributionPromptNative
        payload["busy"] = dictionaryBusy
        payload["notice"] = dictionaryNotice ?? NSNull()
        payload["personalJSON"] = personalDictionaryJSON ?? NSNull()
        payload["dailyContributionLimit"] = 50; payload["serverRetentionDays"] = 7
        return payload
    }
}
