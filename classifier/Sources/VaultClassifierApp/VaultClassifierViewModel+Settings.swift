import Foundation
import VaultClassifierCore
import VaultClassifierResearch
import VaultClassifierBridge

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

    /// Persists a group's evidence threshold and tagging instructions.
    func saveClassifierTypeTagging(typeID: String, settings: TaggingSettings) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  let index = catalog.classifierTypes.firstIndex(where: { $0.id == typeID }),
                  catalog.classifierTypes[index].applicablePlatformIDs.allSatisfy({
                      CollectionPlatformRegistry.definition(for: $0)?.supportsLocalModel == true
                  }) else {
                throw WebBridgeInputError.invalidChoice("Classifier group")
            }
            catalog.classifierTypes[index].tagging = settings
            catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    /// Every tag uses the same required evidence grade; blank instructions add no rules.
    static func parseClassifierTypeTaggingWebInput(
        _ data: [String: Any]
    ) throws -> ClassifierTypeTaggingWebInput {
        guard let typeID = data["typeID"] as? String, !typeID.isEmpty, typeID.count <= 256 else {
            throw WebBridgeInputError.missingValue("typeID")
        }
        let rawConfidence = data["minimumConfidence"]
        let confidence: Int?
        if let number = rawConfidence as? NSNumber, !Self.isJSONBoolean(number),
           (1...5).contains(number.doubleValue), number.doubleValue.rounded() == number.doubleValue {
            confidence = number.intValue
        } else if let value = rawConfidence as? String { confidence = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        else { confidence = nil }
        guard let confidence, (1...5).contains(confidence) else { throw WebBridgeInputError.invalidChoice("minimumConfidence") }
        let houseRules = data["houseRules"] as? String ?? ""
        guard houseRules.count <= TaggingSettings.maximumHouseRulesLength else {
            throw WebBridgeInputError.exceedsLimit("houseRules", TaggingSettings.maximumHouseRulesLength)
        }
        return .init(typeID: typeID, settings: .init(minimumConfidence: confidence, houseRules: houseRules))
    }

    /// Foundation preserves JSON's boolean/number distinction on every host.
    /// A cast to Bool also accepts numeric 0/1 on Apple platforms, so it cannot
    /// validate a confidence field; Windows does not expose CoreFoundation.
    nonisolated private static func isJSONBoolean(_ value: NSNumber) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8) else { return false }
        return json == "[true]" || json == "[false]"
    }

    /// The per-type research form: `researchMode` is "inherit", "on" or "off".

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
