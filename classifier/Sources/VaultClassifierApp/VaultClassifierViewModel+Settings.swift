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

    func saveClassificationSettings(enabled: Bool) {
        do {
            guard let coordinator else { return }
            var settings = coordinator.snapshot().settings
            settings.classificationEnabled = enabled
            try coordinator.updateSettings(settings)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func setClassifierTypePaused(typeID: String, paused: Bool) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let index = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }) else {
                throw WebBridgeInputError.invalidChoice("Classifier group")
            }
            catalog.classifierTypes[index].isPaused = paused
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func saveResearchSettings(_ updated: ResearchSettings) {
        guard let coordinator else { return }
        do {
            guard let catalog = localState?.workspaceCatalog else { return }
            try Self.validateResearchSettingsForEnable(updated, catalog: catalog)
            var current = coordinator.snapshot().settings
            current.research = updated
            try coordinator.updateSettings(current)
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
                throw WebBridgeInputError.invalidChoice("Classifier group research")
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
                throw WebBridgeInputError.invalidChoice("Classifier group local model")
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
        func tagCount(_ key: String, range: ClosedRange<Int>) throws -> Int? {
            guard let value = data[key], !(value is NSNull) else { return nil }
            let raw: String
            if let text = value as? String { raw = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            else if let number = value as? NSNumber, !Self.isJSONBoolean(number) { raw = number.stringValue }
            else { throw WebBridgeInputError.invalidChoice(key) }
            if raw.isEmpty { return nil }
            guard let count = Int(raw), range.contains(count) else { throw WebBridgeInputError.invalidChoice(key) }
            return count
        }
        let minimum = try tagCount("minimumTagsOverride", range: 0...LocalLLMSettings.maximumTagCountOverride)
        let maximum = try tagCount("maximumTagsOverride", range: 1...LocalLLMSettings.maximumTagCountOverride)
        guard (minimum ?? strictness.minimumTags) <= (maximum ?? strictness.maximumTags) else {
            throw WebBridgeInputError.invalidChoice("minimum tags greater than maximum tags")
        }
        return .init(typeID: typeID, settings: .init(speedQuality: speedQuality, strictness: strictness,
            houseRules: houseRules, minimumTagsOverride: minimum, maximumTagsOverride: maximum))
    }

    /// Foundation preserves JSON's boolean/number distinction on every host.
    /// A cast to Bool also accepts numeric 0/1 on Apple platforms, so it cannot
    /// validate a tag-count field; Windows does not expose CoreFoundation.
    nonisolated private static func isJSONBoolean(_ value: NSNumber) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8) else { return false }
        return json == "[true]" || json == "[false]"
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
        guard let value = Int(digits), value >= 0 else { throw AppInputError.invalidNonnegativeNumber(label) }
        return value
    }
}
