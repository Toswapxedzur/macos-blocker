import Foundation
import VaultClassifierCore
import VaultClassifierResearch
import VaultClassifierBridge
import VaultClassifierLLM

// Global and per-type settings: package update mode, local-LLM settings (+ engine reinstall), research settings and their enable-validation, per-type local-model/research overrides and the web-input parsers that feed them.
// Split out of VaultClassifierApp.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour — pinned by ViewModelCharacterizationTests.
@MainActor
extension VaultClassifierViewModel {
    /// A web field that is optional: blank, absent, or unparseable → nil.
    nonisolated static func optionalWebInteger(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return Int(raw)
    }

    func savePackageSettings() {
        do {
            guard let coordinator else { return }
            let settings = ClassifierSettings(
                packageUpdateMode: packageUpdateMode,
                localLLM: llmSettings,
                research: localState?.settings.research ?? ResearchSettings()
            )
            try coordinator.updateSettings(settings)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    /// Persists the local-model settings and rebuilds the engine so every knob
    /// (model file, context, sampling, decline, thresholds) applies immediately.
    func saveLocalLLMSettings(_ updated: LocalLLMSettings) {
        guard let coordinator else { return }
        do {
            llmSettings = updated
            let settings = ClassifierSettings(
                packageUpdateMode: packageUpdateMode,
                localLLM: updated,
                research: localState?.settings.research ?? ResearchSettings()
            )
            try coordinator.updateSettings(settings)
            coordinator.setClassificationOptions(maximumTags: updated.maximumTags, houseRules: updated.houseRules)
            installLocalLLMEngine(coordinator: coordinator)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func saveResearchSettings(_ updated: ResearchSettings) {
        guard let coordinator else { return }
        do {
            guard let catalog = localState?.workspaceCatalog else { return }
            try Self.validateResearchSettingsForEnable(updated, catalog: catalog)
            let current = localState?.settings ?? .init()
            try coordinator.updateSettings(.init(
                packageUpdateMode: current.packageUpdateMode,
                localLLM: current.localLLM,
                research: updated
            ))
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    nonisolated private static func validateResearchSettingsForEnable(
        _ settings: ResearchSettings,
        catalog: WorkspaceCatalog
    ) throws {
        guard settings.enabled else { return }
        guard let llmProfileID = settings.llmProviderProfileID,
              let modelIdentifier = settings.llmModelIdentifier,
              !modelIdentifier.isEmpty,
              let llmProfile = catalog.providerProfiles.first(where: { $0.id == llmProfileID }),
              ProviderGenerationProtocol.supportsGeneration(profile: llmProfile) else {
            throw WebBridgeInputError.invalidChoice("research providers and model")
        }
        _ = try researchCredential(for: llmProfile)

        guard GroundedGenerationProtocol.supportsProviderGrounding(profile: llmProfile) else {
            throw WebBridgeInputError.invalidChoice("grounding-capable provider")
        }
    }

    func saveClassifierTypeResearch(
        typeID: String,
        overrideEnabled: Bool,
        settings: ResearchSettings?
    ) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let index = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }),
                  catalog.classifierTypes[index].applicablePlatformID
                    .flatMap(CollectionPlatformRegistry.definition(for:))?.supportsLocalModel == true else {
                throw WebBridgeInputError.invalidChoice("classifier type research")
            }
            let overrideSettings = overrideEnabled ? settings : nil
            if let overrideSettings {
                try Self.validateResearchSettingsForEnable(overrideSettings, catalog: catalog)
            }
            catalog.classifierTypes[index].researchOverrides = overrideSettings
            catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func saveClassifierTypeLocalModel(
        typeID: String,
        overrideEnabled: Bool,
        modelFileName: String?,
        houseRules: String?,
        allowDecline: Bool?,
        confidenceThresholds: [Double]?,
        thumbnailOcrEvidence: Bool?,
        maximumTags: Int?,
        minimumTags: Int?
    ) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let index = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }),
                  catalog.classifierTypes[index].applicablePlatformID
                    .flatMap(CollectionPlatformRegistry.definition(for:))?.supportsLocalModel == true else {
                throw WebBridgeInputError.invalidChoice("classifier type local model")
            }
            let overrides = overrideEnabled ? LocalModelOverrides(
                houseRules: houseRules,
                allowDecline: allowDecline,
                confidenceThresholds: confidenceThresholds,
                thumbnailOcrEvidence: thumbnailOcrEvidence,
                maximumTags: maximumTags,
                minimumTags: minimumTags
            ) : nil
            catalog.classifierTypes[index].localModelOverrides = overrides?.isEmpty == false ? overrides : nil
            catalog.classifierTypes[index].modelFileName = modelFileName
            catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    static func parseClassifierTypeLocalModelWebInput(
        _ data: [String: Any]
    ) throws -> ClassifierTypeLocalModelWebInput {
        guard let typeID = data["typeID"] as? String, !typeID.isEmpty, typeID.count <= 256 else {
            throw WebBridgeInputError.missingValue("typeID")
        }
        guard let overrideEnabled = data["overrideEnabled"] as? Bool else {
            throw WebBridgeInputError.missingValue("overrideEnabled")
        }
        let modelFileName: String?
        if let rawModelFileName = data["modelFileName"] as? String {
            guard rawModelFileName.count <= 255 else {
                throw WebBridgeInputError.exceedsLimit("modelFileName", 255)
            }
            let cleaned = rawModelFileName.trimmingCharacters(in: .whitespacesAndNewlines)
            modelFileName = cleaned.isEmpty ? nil : cleaned
        } else {
            modelFileName = nil
        }
        guard overrideEnabled else {
            return .init(
                typeID: typeID,
                overrideEnabled: false,
                modelFileName: modelFileName,
                overrides: nil
            )
        }

        let houseRules: String?
        if let raw = data["houseRules"] as? String {
            guard raw.count <= 4_000 else { throw WebBridgeInputError.exceedsLimit("houseRules", 4_000) }
            houseRules = raw
        } else {
            houseRules = nil
        }
        let rawThresholds = ["confidenceBand2", "confidenceBand3", "confidenceBand4", "confidenceBand5"]
            .compactMap { key -> Double? in
                guard let raw = data[key] as? String,
                      let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                      value.isFinite else { return nil }
                return value
            }
        // Empty/blank/unparseable → nil = inherit the global cap; the struct
        // clamps a set value to 1–16.
        let maximumTags: Int?
        if let raw = data["maximumTags"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            maximumTags = trimmed.isEmpty ? nil : Int(trimmed)
        } else {
            maximumTags = data["maximumTags"] as? Int
        }
        let overrides = LocalModelOverrides(
            houseRules: houseRules,
            allowDecline: data["allowDecline"] as? Bool,
            confidenceThresholds: rawThresholds.isEmpty ? nil : rawThresholds,
            thumbnailOcrEvidence: data["thumbnailOcrEvidence"] as? Bool,
            maximumTags: maximumTags,
            minimumTags: Self.optionalWebInteger(data["minimumTags"])
        )
        return .init(
            typeID: typeID,
            overrideEnabled: true,
            modelFileName: modelFileName,
            overrides: overrides.isEmpty ? nil : overrides
        )
    }

    static func parseClassifierTypeResearchWebInput(
        _ data: [String: Any]
    ) throws -> ClassifierTypeResearchWebInput {
        guard let typeID = data["typeID"] as? String, !typeID.isEmpty, typeID.count <= 256 else {
            throw WebBridgeInputError.missingValue("typeID")
        }
        guard let overrideEnabled = data["overrideEnabled"] as? Bool else {
            throw WebBridgeInputError.missingValue("overrideEnabled")
        }
        guard overrideEnabled else {
            return .init(typeID: typeID, overrideEnabled: false, settings: nil)
        }

        let defaults = ResearchSettings()
        func optionalString(_ key: String) -> String? { data[key] as? String }
        func optionalInteger(_ key: String) -> Int? {
            guard let raw = data[key] as? String else { return nil }
            return Int(raw.replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        func optionalDouble(_ key: String) -> Double? {
            guard let raw = data[key] as? String else { return nil }
            return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .init(
            typeID: typeID,
            overrideEnabled: true,
            settings: ResearchSettings(
                enabled: data["enabled"] as? Bool ?? defaults.enabled,
                llmProviderProfileID: optionalString("llmProviderProfileID"),
                llmModelIdentifier: optionalString("llmModelIdentifier"),
                requestsPerMinute: optionalInteger("requestsPerMinute") ?? defaults.requestsPerMinute,
                dailyTokenLimit: optionalInteger("dailyTokenLimit") ?? defaults.dailyTokenLimit,
                cooldownHours: optionalInteger("cooldownHours") ?? defaults.cooldownHours,
                authorThreshold: AuthorResearchThreshold(
                    level: optionalDouble("authorLevel") ?? defaults.authorThreshold.level,
                    count: optionalInteger("authorCount") ?? defaults.authorThreshold.count,
                    windowDays: optionalInteger("authorWindowDays") ?? defaults.authorThreshold.windowDays
                ),
                knowledgeTTLDays: optionalInteger("knowledgeTTLDays") ?? defaults.knowledgeTTLDays,
                maxKnowledgePerVideo: optionalInteger("maxKnowledgePerVideo") ?? defaults.maxKnowledgePerVideo
            )
        )
    }

    func loadResourceSettings(from settings: ClassifierSettings) {
        packageUpdateMode = settings.packageUpdateMode
        llmSettings = settings.localLLM
        coordinator?.setClassificationOptions(
            maximumTags: settings.localLLM.maximumTags,
            houseRules: settings.localLLM.houseRules
        )
    }

    func positiveInteger(_ raw: String, label: String) throws -> Int {
        let digits = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits), value > 0 else { throw AppInputError.invalidNumber(label) }
        return value
    }

    func positiveNumber(_ raw: String, label: String) throws -> Double {
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0, value.isFinite else {
            throw AppInputError.invalidDecimal(label)
        }
        return value
    }

    func nonnegativeInteger(_ raw: String, label: String) throws -> Int {
        let digits = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits), value >= 0 else { throw AppInputError.invalidNumber(label) }
        return value
    }
}
