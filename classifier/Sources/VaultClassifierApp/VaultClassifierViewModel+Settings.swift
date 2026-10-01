import Foundation
import VaultClassifierCore
import VaultClassifierResearch
import VaultClassifierBridge
import VaultClassifierLLM

// Package/research settings, independent group dials and house rules, and web-input validation.
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
                research: localState?.settings.research ?? ResearchSettings()
            )
            try coordinator.updateSettings(settings)
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
                  catalog.classifierTypes[index].applicablePlatformIDs.allSatisfy({
                      CollectionPlatformRegistry.definition(for: $0)?.supportsLocalModel == true
                  }) else {
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

    /// Persists a group's independent dial positions and house rules.
    func saveClassifierTypeLocalModel(typeID: String, settings: LocalLLMSettings) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let index = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }),
                  catalog.classifierTypes[index].applicablePlatformIDs.allSatisfy({
                      CollectionPlatformRegistry.definition(for: $0)?.supportsLocalModel == true
                  }) else {
                throw WebBridgeInputError.invalidChoice("classifier type local model")
            }
            catalog.classifierTypes[index].localModel = settings
            catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    /// Both dial positions are required; blank house rules means no rules.
    static func parseClassifierTypeLocalModelWebInput(
        _ data: [String: Any]
    ) throws -> ClassifierTypeLocalModelWebInput {
        guard let typeID = data["typeID"] as? String, !typeID.isEmpty, typeID.count <= 256 else {
            throw WebBridgeInputError.missingValue("typeID")
        }
        guard let speedQuality = SpeedQualityDial.resolve(data["speedQuality"] as? String) else {
            throw WebBridgeInputError.invalidChoice("speedQuality")
        }
        guard let strictness = StrictnessDial.resolve(optionalWebInteger(data["strictness"])) else {
            throw WebBridgeInputError.invalidChoice("strictness")
        }
        let houseRules = data["houseRules"] as? String ?? ""
        guard houseRules.count <= LocalLLMSettings.maximumHouseRulesLength else {
            throw WebBridgeInputError.exceedsLimit("houseRules", LocalLLMSettings.maximumHouseRulesLength)
        }
        return .init(typeID: typeID, settings: .init(speedQuality: speedQuality, strictness: strictness, houseRules: houseRules))
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
