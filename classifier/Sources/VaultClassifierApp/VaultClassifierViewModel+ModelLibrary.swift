import Foundation
import VaultClassifierCore
import VaultClassifierBridge
import VaultClassifierLLM

// The GGUF model library: user-initiated downloads with progress, cancellation and deletion of model files.
// Split out of VaultClassifierApp.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour — pinned by ViewModelCharacterizationTests.
@MainActor
extension VaultClassifierViewModel {
    func downloadModel(id: String) {
        guard let entry = LocalModelCatalog.entry(id: id) else {
            issue = "The selected model is not in the local catalog."
            return
        }
        guard !VaultLocalLLMEngine.availableModelFiles().contains(entry.ggufFileName) else {
            modelDownloadFractions.removeValue(forKey: id)
            issue = nil
            return
        }
        guard modelDownloadFractions[id] == nil else { return }
        modelDownloadFractions[id] = 0
        issue = nil
        let manager = modelDownloadManager
        let reportProgress: ModelDownloadManager.ProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.modelDownloadFractions[id] = progress.fraction
                self.onWebStateChange?()
            }
        }
        Task { [weak self] in
            do {
                _ = try await manager.download(entry, progress: reportProgress)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.modelDownloadFractions.removeValue(forKey: id)
                    self.issue = nil
                    // The Speed↔Quality dial already names the model; if this download
                    // is the dial's tier, load it now.
                    if entry.tier == self.llmSettings.speedQuality, let coordinator = self.coordinator {
                        self.installLocalLLMEngine(coordinator: coordinator)
                    }
                    self.onWebStateChange?()
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.modelDownloadFractions.removeValue(forKey: id)
                    self.onWebStateChange?()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.modelDownloadFractions.removeValue(forKey: id)
                    self.issue = error.localizedDescription
                    self.onWebStateChange?()
                }
            }
        }
    }

    func cancelModelDownload(id: String) {
        guard LocalModelCatalog.entry(id: id) != nil else {
            issue = "The selected model is not in the local catalog."
            return
        }
        modelDownloadFractions.removeValue(forKey: id)
        let manager = modelDownloadManager
        Task { [weak self] in
            await manager.cancel(id: id)
            await MainActor.run { [weak self] in
                self?.onWebStateChange?()
            }
        }
    }

    func deleteModelFile(fileName: String) {
        let manager = modelDownloadManager
        Task { [weak self] in
            do {
                try await manager.deleteModelFile(fileName: fileName)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.issue = nil
                    self.onWebStateChange?()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.issue = error.localizedDescription
                    self.onWebStateChange?()
                }
            }
        }
    }
}
