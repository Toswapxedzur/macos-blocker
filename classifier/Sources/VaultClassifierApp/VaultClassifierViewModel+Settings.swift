import Foundation
import VaultClassifierCore
import VaultClassifierResearch
import VaultClassifierBridge
import VaultClassifierLLM

// Global and per-type settings: package update mode, the two dials + house rules (+ engine reinstall), research on/off + provider and its enable-validation, per-type dial/house-rule/research overrides and the web-input parsers that feed them.
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

    /// Persists the dials and house rules and rebuilds the engine so a new
    /// Speed↔Quality tier loads immediately.
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
            coordinator.setClassificationOptions(houseRules: updated.houseRules)
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

    /// Sets a type's own research switch (nil = follow the global switch). The
    /// global consent stays the master gate.
    func saveClassifierTypeResearch(typeID: String, researchEnabled: Bool?) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let index = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }),
                  catalog.classifierTypes[index].applicablePlatformID
                    .flatMap(CollectionPlatformRegistry.definition(for:))?.supportsLocalModel == true else {
                throw WebBridgeInputError.invalidChoice("classifier type research")
            }
            catalog.classifierTypes[index].researchEnabled = researchEnabled
            catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    /// Sets a type's own dial positions and house rules (nil / empty = follow
    /// the global settings).
    func saveClassifierTypeLocalModel(typeID: String, overrides: LocalModelOverrides?) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let index = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }),
                  catalog.classifierTypes[index].applicablePlatformID
                    .flatMap(CollectionPlatformRegistry.definition(for:))?.supportsLocalModel == true else {
                throw WebBridgeInputError.invalidChoice("classifier type local model")
            }
            catalog.classifierTypes[index].localModelOverrides = overrides?.isEmpty == false ? overrides : nil
            catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    /// The per-type local-model form: `speedQuality` ("" or a tier), `strictness`
    /// ("" or 1–5) and `houseRules` (blank = none). Anything blank follows the
    /// global setting; an unknown position is refused.
    static func parseClassifierTypeLocalModelWebInput(
        _ data: [String: Any]
    ) throws -> ClassifierTypeLocalModelWebInput {
        guard let typeID = data["typeID"] as? String, !typeID.isEmpty, typeID.count <= 256 else {
            throw WebBridgeInputError.missingValue("typeID")
        }
        let speedQuality: SpeedQualityDial?
        if let raw = (data["speedQuality"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let resolved = SpeedQualityDial.resolve(raw) else { throw WebBridgeInputError.invalidChoice("speedQuality") }
            speedQuality = resolved
        } else {
            speedQuality = nil
        }
        let strictness: StrictnessDial?
        if let raw = optionalWebInteger(data["strictness"]) {
            guard let resolved = StrictnessDial.resolve(raw) else { throw WebBridgeInputError.invalidChoice("strictness") }
            strictness = resolved
        } else if let raw = (data["strictness"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            throw WebBridgeInputError.invalidChoice("strictness")
        } else {
            strictness = nil
        }
        let houseRules: String?
        if let raw = data["houseRules"] as? String {
            guard raw.count <= LocalLLMSettings.maximumHouseRulesLength else {
                throw WebBridgeInputError.exceedsLimit("houseRules", LocalLLMSettings.maximumHouseRulesLength)
            }
            houseRules = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
        } else {
            houseRules = nil
        }
        let overrides = LocalModelOverrides(houseRules: houseRules, speedQuality: speedQuality, strictness: strictness)
        return .init(typeID: typeID, overrides: overrides.isEmpty ? nil : overrides)
    }

    /// The per-type research form: `researchMode` is "inherit", "on" or "off".
    static func parseClassifierTypeResearchWebInput(
        _ data: [String: Any]
    ) throws -> ClassifierTypeResearchWebInput {
        guard let typeID = data["typeID"] as? String, !typeID.isEmpty, typeID.count <= 256 else {
            throw WebBridgeInputError.missingValue("typeID")
        }
        switch (data["researchMode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "inherit", nil, "": return .init(typeID: typeID, researchEnabled: nil)
        case "on": return .init(typeID: typeID, researchEnabled: true)
        case "off": return .init(typeID: typeID, researchEnabled: false)
        default: throw WebBridgeInputError.invalidChoice("researchMode")
        }
    }

    func loadResourceSettings(from settings: ClassifierSettings) {
        packageUpdateMode = settings.packageUpdateMode
        llmSettings = settings.localLLM
        coordinator?.setClassificationOptions(houseRules: settings.localLLM.houseRules)
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
