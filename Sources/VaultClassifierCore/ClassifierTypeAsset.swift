import Foundation

// A classifier type: its tree/dataset/model binding, per-type overrides and preset drift.
// (Split out of the former WorkspaceAssets.swift; CLASSIFIER-INDEPENDENCE §7.)

public struct ClassifierTypeAsset: Codable, Equatable, Sendable, Identifiable {
    public static let maximumNameLength = 128

    public var id: String
    public var name: String
    public var treeID: String
    public var treeRevision: Int
    public var datasetID: String
    public var datasetRevision: Int
    /// One platform binding supplies this type's tree and collected local
    /// classification data. A type cannot combine platform sources.
    public var applicablePlatformID: String?
    /// Optional request-time overrides for this type. Context/runtime controls
    /// stay global and apply to every resident model engine.
    public var localModelOverrides: LocalModelOverrides?
    /// Nil inherits the app-wide model choice. A file name selects a resident
    /// per-type GGUF engine while retaining global runtime controls.
    public var modelFileName: String?
    /// Optional grounded-research defaults for this type. The app-wide
    /// research consent remains the master gate even when this value enables
    /// research for the type.
    public var researchOverrides: ResearchSettings?
    /// The preset a person chose when creating this type (a `VaultPreset`
    /// rawValue), or nil for legacy/hand-built types. Stored as a string so an
    /// unknown preset from a newer build survives a round-trip. Advanced edits
    /// keep it, so the UI can flag "modified from <preset>".
    public var presetID: String?
    /// Position in the reorderable classifier-type list. Types targeting the
    /// same platform apply in ascending order; a card unions their tags in this
    /// order.
    public var order: Int
    public var updatedAtMilliseconds: Int64

    public init(
        id: String = UUID().uuidString,
        name: String,
        treeID: String,
        treeRevision: Int,
        datasetID: String,
        datasetRevision: Int,
        applicablePlatformID: String? = nil,
        localModelOverrides: LocalModelOverrides? = nil,
        modelFileName: String? = nil,
        researchOverrides: ResearchSettings? = nil,
        presetID: String? = nil,
        order: Int = 0,
        updatedAtMilliseconds: Int64 = WorkspaceCatalog.now()
    ) {
        self.id = id
        self.name = name
        self.treeID = treeID
        self.treeRevision = treeRevision
        self.datasetID = datasetID
        self.datasetRevision = datasetRevision
        let cleanedPlatformID = applicablePlatformID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.applicablePlatformID = cleanedPlatformID.isEmpty ? nil : cleanedPlatformID
        self.localModelOverrides = localModelOverrides?.isEmpty == false ? localModelOverrides : nil
        let cleanedModelFileName = modelFileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.modelFileName = cleanedModelFileName.isEmpty ? nil : String(cleanedModelFileName.prefix(255))
        self.researchOverrides = researchOverrides
        let cleanedPresetID = presetID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.presetID = cleanedPresetID.isEmpty ? nil : String(cleanedPresetID.prefix(64))
        self.order = order
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, treeID, treeRevision, datasetID, datasetRevision, applicablePlatformID,
             localModelOverrides, modelFileName, researchOverrides, presetID, order, updatedAtMilliseconds
    }

    private enum RetiredCodingKeys: String, CodingKey {
        case dataSourcePlatformIDs, localModelID, selectedLLMProviderProfileID,
             llmAssistDraftConfiguration, llmAssistConfiguration, llmProfileIDs,
             decisionPriority, platformLocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        treeID = try container.decode(String.self, forKey: .treeID)
        treeRevision = try container.decode(Int.self, forKey: .treeRevision)
        datasetID = try container.decode(String.self, forKey: .datasetID)
        datasetRevision = try container.decode(Int.self, forKey: .datasetRevision)
        let decodedPlatformID = (try container.decodeIfPresent(String.self, forKey: .applicablePlatformID)?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        if !decodedPlatformID.isEmpty {
            applicablePlatformID = decodedPlatformID
        } else {
            // The retired multi-source field is read only as a bounded crash
            // guard. It can be preserved only when it already described one
            // platform; a combined legacy type must be configured again.
            let legacyPlatformIDs = Array(Set(try retired.decodeIfPresent([String].self, forKey: .dataSourcePlatformIDs) ?? []))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            applicablePlatformID = legacyPlatformIDs.count == 1 ? legacyPlatformIDs[0] : nil
        }
        // Removed trainable-model and per-type provider-assist fields are
        // accepted only as retired keys so old state opens safely. Their values
        // are deliberately discarded and are never re-encoded.
        _ = retired.contains(.localModelID)
        _ = retired.contains(.selectedLLMProviderProfileID)
        _ = retired.contains(.llmAssistDraftConfiguration)
        _ = retired.contains(.llmAssistConfiguration)
        _ = retired.contains(.llmProfileIDs)
        _ = retired.contains(.decisionPriority)
        _ = retired.contains(.platformLocked)
        let decodedOverrides = try container.decodeIfPresent(LocalModelOverrides.self, forKey: .localModelOverrides)
        localModelOverrides = decodedOverrides?.isEmpty == false ? decodedOverrides : nil
        let decodedModelFileName = try container.decodeIfPresent(String.self, forKey: .modelFileName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        modelFileName = decodedModelFileName.isEmpty ? nil : String(decodedModelFileName.prefix(255))
        researchOverrides = try container.decodeIfPresent(ResearchSettings.self, forKey: .researchOverrides)
        let decodedPresetID = try container.decodeIfPresent(String.self, forKey: .presetID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        presetID = decodedPresetID.isEmpty ? nil : String(decodedPresetID.prefix(64))
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        updatedAtMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMilliseconds)
            ?? WorkspaceCatalog.now()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(treeID, forKey: .treeID)
        try container.encode(treeRevision, forKey: .treeRevision)
        try container.encode(datasetID, forKey: .datasetID)
        try container.encode(datasetRevision, forKey: .datasetRevision)
        try container.encodeIfPresent(applicablePlatformID, forKey: .applicablePlatformID)
        try container.encodeIfPresent(localModelOverrides, forKey: .localModelOverrides)
        try container.encodeIfPresent(modelFileName, forKey: .modelFileName)
        try container.encodeIfPresent(researchOverrides, forKey: .researchOverrides)
        try container.encodeIfPresent(presetID, forKey: .presetID)
        try container.encode(order, forKey: .order)
        try container.encode(updatedAtMilliseconds, forKey: .updatedAtMilliseconds)
    }
}
