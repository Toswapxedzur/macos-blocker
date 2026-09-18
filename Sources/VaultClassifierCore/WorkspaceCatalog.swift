import Foundation

// The aggregate root of all authored + collected workspace state, its validation, histograms and trash.
// (Split out of the former WorkspaceAssets.swift; CLASSIFIER-INDEPENDENCE §7.)

public enum WorkspaceCatalogError: Error, Equatable, LocalizedError, Sendable {
    case duplicateIdentifier(String)
    case missingTree(String)
    case missingDataset(String)
    case missingClassifierType(String)
    case incompatibleActiveClassifierType(String)
    case unsupportedCollectionPlatform(String)
    case invalidCollectedEntry(String)
    case invalidProviderProfile(String)
    case invalidClassifierType(String)
    case treeInUse(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateIdentifier(let value): return "Duplicate local asset identifier: \(value)."
        case .missingTree(let value): return "The platform binding references a missing tag tree: \(value)."
        case .missingDataset(let value): return "The platform binding references a missing classification dataset: \(value)."
        case .missingClassifierType(let value): return "The platform binding references a missing classifier type: \(value)."
        case .incompatibleActiveClassifierType(let value): return "The active classifier type is not compatible with the platform tree and dataset: \(value)."
        case .unsupportedCollectionPlatform(let value): return "The collection platform is not supported: \(value)."
        case .invalidCollectedEntry(let value): return "The collected platform entry is invalid: \(value)."
        case .invalidProviderProfile(let value): return "The API provider profile is invalid: \(value)."
        case .invalidClassifierType(let value): return "The classifier type has incompatible local assets: \(value)."
        case .treeInUse(let value): return "The tag tree is still used by a classifier type or platform: \(value)."
        }
    }
}

public enum TrashedEntryKind: String, Codable, Sendable, CaseIterable {
    case classifierType
    case collectionPlatform
    case tagTree
}

/// A self-contained snapshot of a deleted entity and every dependent record it
/// owned, so a restore re-inserts the whole thing. Only the fields relevant to
/// `kind` are populated. Entries are opportunistically purged 24h after
/// deletion (there is no background timer).
public struct TrashedEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: TrashedEntryKind
    public var name: String
    public var deletedAtMilliseconds: Int64
    public var classifierType: ClassifierTypeAsset?
    public var binding: PlatformBinding?
    public var tree: TagTreeAsset?
    public var datasetID: String?
    public var collectedEntries: [CollectedPlatformEntry]

    public init(
        id: String = UUID().uuidString,
        kind: TrashedEntryKind,
        name: String,
        deletedAtMilliseconds: Int64 = WorkspaceCatalog.now(),
        classifierType: ClassifierTypeAsset? = nil,
        binding: PlatformBinding? = nil,
        tree: TagTreeAsset? = nil,
        datasetID: String? = nil,
        collectedEntries: [CollectedPlatformEntry] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.deletedAtMilliseconds = deletedAtMilliseconds
        self.classifierType = classifierType
        self.binding = binding
        self.tree = tree
        self.datasetID = datasetID
        self.collectedEntries = collectedEntries
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, deletedAtMilliseconds, classifierType, binding, tree
        case datasetID, collectedEntries
    }

    private enum RetiredCodingKeys: String, CodingKey { case creatorClassifications, models }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        _ = retired.contains(.creatorClassifications)
        _ = retired.contains(.models)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(TrashedEntryKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        deletedAtMilliseconds = try container.decode(Int64.self, forKey: .deletedAtMilliseconds)
        classifierType = try container.decodeIfPresent(ClassifierTypeAsset.self, forKey: .classifierType)
        binding = try container.decodeIfPresent(PlatformBinding.self, forKey: .binding)
        tree = try container.decodeIfPresent(TagTreeAsset.self, forKey: .tree)
        datasetID = try container.decodeIfPresent(String.self, forKey: .datasetID)
        collectedEntries = try container.decodeIfPresent([CollectedPlatformEntry].self, forKey: .collectedEntries) ?? []
    }

    /// Default 24-hour trash lifetime, expressed in milliseconds.
    public static let defaultTTLMilliseconds: Int64 = 24 * 60 * 60 * 1_000
}

public struct WorkspaceCatalog: Codable, Equatable, Sendable {
    public var trees: [TagTreeAsset]
    public var datasets: [ClassificationDataset]
    public var bindings: [PlatformBinding]
    /// Reusable decision brains. A platform may later select one explicitly;
    /// the asset itself does not grant a browser or provider permission.
    public var classifierTypes: [ClassifierTypeAsset]
    public var tokenUsage: [TokenUsageRecord]
    public var providerRequestRecords: [ProviderRequestRecord]
    /// Provider profiles include their saved connection fields, including the
    /// ordinary API key/token text. They remain local to workspace state and
    /// the local WebView; browser-bridge messages and request diagnostics do
    /// not include them.
    public var providerProfiles: [APIKeyProviderProfile]
    public var trash: [TrashedEntry]
    // Local-LLM rework stores (additive; see LocalLLMModel.swift). Primary per-video
    // labels, the grounded-research knowledge map, user corrections, and the derived
    // creator priors. Empty until the new pipeline populates them.
    public var videoClassifications: [VideoClassification]
    /// Term knowledge only. Creator descriptions live in `creatorKnowledge`, a
    /// deliberately separate, permanent map (creator identities are keyed
    /// forever and are used as a low-confidence classification fallback rather
    /// than injected into every decode).
    public var knowledgeEntries: [KnowledgeEntry]
    /// Creator descriptions, keyed by creator id — permanent and stored apart
    /// from term knowledge.
    public var creatorKnowledge: [KnowledgeEntry]
    public var researchAttempts: [ResearchAttemptRecord]
    public var correctionExamples: [CorrectionExample]
    public var creatorHistograms: [CreatorTagHistogram]
    /// Per-creator (per classifier type) accumulator of derived research urgency,
    /// windowed — drives author research (RESEARCH-REDESIGN §8).
    public var creatorResearchAccumulators: [CreatorResearchAccumulator]

    public init(trees: [TagTreeAsset] = [], datasets: [ClassificationDataset] = [], bindings: [PlatformBinding] = [], classifierTypes: [ClassifierTypeAsset] = [], tokenUsage: [TokenUsageRecord] = [], providerRequestRecords: [ProviderRequestRecord] = [], providerProfiles: [APIKeyProviderProfile] = [], trash: [TrashedEntry] = [], videoClassifications: [VideoClassification] = [], knowledgeEntries: [KnowledgeEntry] = [], creatorKnowledge: [KnowledgeEntry] = [], researchAttempts: [ResearchAttemptRecord] = [], correctionExamples: [CorrectionExample] = [], creatorHistograms: [CreatorTagHistogram] = [], creatorResearchAccumulators: [CreatorResearchAccumulator] = []) {
        self.trees = trees
        self.datasets = datasets
        self.bindings = bindings
        self.classifierTypes = classifierTypes
        self.tokenUsage = tokenUsage
        self.providerRequestRecords = providerRequestRecords
        self.providerProfiles = providerProfiles
        self.trash = trash
        self.videoClassifications = videoClassifications
        self.knowledgeEntries = knowledgeEntries
        self.creatorKnowledge = creatorKnowledge
        self.researchAttempts = researchAttempts
        self.correctionExamples = correctionExamples
        self.creatorHistograms = creatorHistograms
        self.creatorResearchAccumulators = creatorResearchAccumulators
    }

    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    public static func starter() -> WorkspaceCatalog {
        // A personal tree begins as an empty canvas. The Vault taxonomy remains
        // an optional import rather than an imposed first node or hierarchy.
        let tree = TagTreeAsset(id: "vault-starter", name: "Vault starter tree", nodes: [])
        let dataset = ClassificationDataset(id: "local-dataset", name: "Local classification data")
        // Every supported platform is collected by default; the person turns any
        // one off rather than adding them one at a time. Bindings share the local
        // dataset (entries self-tag with their platform); classifier types own
        // their own trees, so the shared starter tree is only the binding anchor.
        let bindings = CollectionPlatformRegistry.definitions.map { definition in
            PlatformBinding(
                id: definition.id,
                name: definition.name,
                browser: definition.browser,
                treeID: tree.id,
                datasetID: dataset.id,
                collectionEnabled: true
            )
        }
        return .init(trees: [tree], datasets: [dataset], bindings: bindings)
    }

    public func validate() throws {
        try unique(trees.map(\.id) + datasets.map(\.id) + bindings.map(\.id) + classifierTypes.map(\.id) + providerProfiles.map(\.id))
        try validateLocalLLMStores()
        for binding in bindings {
            guard CollectionPlatformRegistry.definition(for: binding.id) != nil else {
                throw WorkspaceCatalogError.unsupportedCollectionPlatform(binding.id)
            }
            guard let tree = trees.first(where: { $0.id == binding.treeID }) else { throw WorkspaceCatalogError.missingTree(binding.treeID) }
            guard let dataset = datasets.first(where: { $0.id == binding.datasetID }) else { throw WorkspaceCatalogError.missingDataset(binding.datasetID) }
            _ = tree
            _ = dataset
        }
        for dataset in datasets {
            guard dataset.collectedEntries.count <= CollectedPlatformEntry.maximumRetainedEntries else {
                throw WorkspaceCatalogError.invalidCollectedEntry(dataset.id)
            }
            var seenEntries = Set<String>()
            for entry in dataset.collectedEntries {
                guard CollectionPlatformRegistry.definition(for: entry.platformID) != nil,
                      !entry.id.isEmpty,
                      !entry.entryID.isEmpty,
                      !entry.creatorID.isEmpty,
                      !entry.creatorName.isEmpty,
                      !entry.entryType.isEmpty,
                      !entry.title.isEmpty,
                      entry.title.count <= EntryEvidenceValidator.titleLimit,
                      entry.text.map({ !$0.isEmpty && $0.count <= EntryEvidenceValidator.textLimit }) ?? true,
                      entry.summary.map({ !$0.isEmpty && $0.count <= EntryEvidenceValidator.summaryLimit }) ?? true,
                      entry.suppliedTags.count <= CollectedPlatformEntry.maximumSuppliedTags,
                      entry.suppliedTags.allSatisfy({
                          !$0.isEmpty &&
                          $0.count <= EntryEvidenceValidator.tagLengthLimit &&
                          $0.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
                      }),
                      entry.sourceIconURL.map({
                          SourceIconURLPolicy.isAccepted(platformID: entry.platformID, value: $0)
                      }) ?? true,
                      entry.attributes.count <= CollectedPlatformEntry.maximumAttributes,
                      entry.attributes.allSatisfy({ key, value in
                          !key.isEmpty && key.count <= CollectedPlatformEntry.maximumAttributeKeyLength &&
                          value.count <= CollectedPlatformEntry.maximumAttributeValueLength &&
                          key.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) &&
                          value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
                      }),
                      entry.observationCount > 0,
                      seenEntries.insert(entry.deduplicationKey).inserted else {
                    throw WorkspaceCatalogError.invalidCollectedEntry(entry.id)
                }
            }
        }
        for classifierType in classifierTypes {
            guard !classifierType.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  classifierType.name.count <= ClassifierTypeAsset.maximumNameLength,
                  let tree = trees.first(where: { $0.id == classifierType.treeID }),
                  tree.revision == classifierType.treeRevision,
                  let dataset = datasets.first(where: { $0.id == classifierType.datasetID }),
                  dataset.revision == classifierType.datasetRevision,
                  (classifierType.applicablePlatformID == nil || (classifierType.applicablePlatformID?.count ?? 0) <= 64),
                  (classifierType.applicablePlatformID == nil || bindings.contains(where: { binding in
                      // Multiple types may target one platform, each owning its own
                      // tree; only the platform + shared dataset must match here.
                      binding.id == classifierType.applicablePlatformID && binding.datasetID == dataset.id
                  })) else {
                throw WorkspaceCatalogError.invalidClassifierType(classifierType.id)
            }
        }
        for binding in bindings {
            guard let classifierTypeID = binding.activeClassifierTypeID else { continue }
            guard let classifierType = classifierTypes.first(where: { $0.id == classifierTypeID }) else {
                throw WorkspaceCatalogError.missingClassifierType(classifierTypeID)
            }
            guard classifierType.treeID == binding.treeID,
                  classifierType.datasetID == binding.datasetID,
                  classifierType.applicablePlatformID == binding.id,
                  let tree = trees.first(where: { $0.id == binding.treeID }),
                  let dataset = datasets.first(where: { $0.id == binding.datasetID }),
                  classifierType.treeRevision == tree.revision,
                  classifierType.datasetRevision == dataset.revision else {
                throw WorkspaceCatalogError.incompatibleActiveClassifierType(classifierTypeID)
            }
        }
        for profile in providerProfiles {
            do {
                try profile.validate()
            } catch {
                throw WorkspaceCatalogError.invalidProviderProfile(profile.id)
            }
        }
        for record in providerRequestRecords {
            guard providerProfiles.contains(where: { $0.id == record.profileID }),
                  record.durationMilliseconds >= 0 else {
                throw WorkspaceCatalogError.invalidProviderProfile(record.profileID)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case trees, datasets, bindings, classifierTypes, tokenUsage, providerRequestRecords, providerProfiles, trash,
             videoClassifications, knowledgeEntries, creatorKnowledge, researchAttempts, correctionExamples, creatorHistograms,
             creatorResearchAccumulators
    }

    private enum RetiredCodingKeys: String, CodingKey { case models }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        _ = retired.contains(.models)
        trees = try container.decodeIfPresent([TagTreeAsset].self, forKey: .trees) ?? []
        datasets = try container.decodeIfPresent([ClassificationDataset].self, forKey: .datasets) ?? []
        bindings = try container.decodeIfPresent([PlatformBinding].self, forKey: .bindings) ?? []
        classifierTypes = try container.decodeIfPresent([ClassifierTypeAsset].self, forKey: .classifierTypes) ?? []
        tokenUsage = try container.decodeIfPresent([TokenUsageRecord].self, forKey: .tokenUsage) ?? []
        providerRequestRecords = try container.decodeIfPresent([ProviderRequestRecord].self, forKey: .providerRequestRecords) ?? []
        providerProfiles = try container.decodeIfPresent([APIKeyProviderProfile].self, forKey: .providerProfiles) ?? []
        trash = try container.decodeIfPresent([TrashedEntry].self, forKey: .trash) ?? []
        videoClassifications = try container.decodeIfPresent([VideoClassification].self, forKey: .videoClassifications) ?? []
        // Migration: older states stored terms and creators together in
        // `knowledgeEntries`. Keep terms there and move any creator entries into
        // the dedicated `creatorKnowledge` map. New states already write both.
        let decodedKnowledge = try container.decodeIfPresent([KnowledgeEntry].self, forKey: .knowledgeEntries) ?? []
        let decodedCreatorKnowledge = try container.decodeIfPresent([KnowledgeEntry].self, forKey: .creatorKnowledge) ?? []
        knowledgeEntries = decodedKnowledge.filter { $0.kind == .term }
        var creators = decodedCreatorKnowledge.filter { $0.kind == .creator }
        var creatorKeys = Set(creators.map(\.id))
        for entry in decodedKnowledge where entry.kind == .creator && creatorKeys.insert(entry.id).inserted {
            creators.append(entry)
        }
        creatorKnowledge = creators
        researchAttempts = try container.decodeIfPresent([ResearchAttemptRecord].self, forKey: .researchAttempts) ?? []
        correctionExamples = try container.decodeIfPresent([CorrectionExample].self, forKey: .correctionExamples) ?? []
        creatorHistograms = try container.decodeIfPresent([CreatorTagHistogram].self, forKey: .creatorHistograms) ?? []
        creatorResearchAccumulators = try container.decodeIfPresent([CreatorResearchAccumulator].self, forKey: .creatorResearchAccumulators) ?? []
    }

    private func unique(_ identifiers: [String]) throws {
        guard Set(identifiers).count == identifiers.count else {
            throw WorkspaceCatalogError.duplicateIdentifier("workspace catalog")
        }
    }

    /// Returns the local classification-data binding for a supported platform,
    /// creating it from this catalog's default tree and dataset when the
    /// platform has not been added yet. A platform is added at most once.
    @discardableResult
    public mutating func ensurePlatformBinding(_ platformID: String) throws -> PlatformBinding {
        guard let definition = CollectionPlatformRegistry.definition(for: platformID) else {
            throw WorkspaceCatalogError.unsupportedCollectionPlatform(platformID)
        }
        if let existing = bindings.first(where: { $0.id == definition.id }) {
            return existing
        }
        guard let tree = trees.first else {
            throw WorkspaceCatalogError.missingTree("workspace default")
        }
        guard let dataset = datasets.first else {
            throw WorkspaceCatalogError.missingDataset("workspace default")
        }
        let binding = PlatformBinding(
            id: definition.id,
            name: definition.name,
            browser: definition.browser,
            treeID: tree.id,
            datasetID: dataset.id,
            collectionEnabled: true
        )
        bindings.append(binding)
        return binding
    }

    /// Removes one local platform binding and its collected public entries.
    /// Shared tree and dataset assets are retained.
    @discardableResult
    public mutating func removePlatformBinding(_ platformID: String) -> Bool {
        guard let bindingIndex = bindings.firstIndex(where: { $0.id == platformID }) else {
            return false
        }

        let binding = bindings.remove(at: bindingIndex)
        if let datasetIndex = datasets.firstIndex(where: { $0.id == binding.datasetID }) {
            datasets[datasetIndex].collectedEntries.removeAll(where: { $0.platformID == platformID })
        }
        reconcileClassifierTypes()
        return true
    }

    // MARK: - Trash (soft delete)

    /// Moves a classifier type into trash.
    @discardableResult
    public mutating func trashClassifierType(_ typeID: String) -> TrashedEntry? {
        guard let index = classifierTypes.firstIndex(where: { $0.id == typeID }) else { return nil }
        let type = classifierTypes.remove(at: index)
        for bindingIndex in bindings.indices where bindings[bindingIndex].activeClassifierTypeID == typeID {
            bindings[bindingIndex].activeClassifierTypeID = nil
        }
        let entry = TrashedEntry(
            kind: .classifierType,
            name: type.name,
            classifierType: type,
            datasetID: type.datasetID
        )
        trash.append(entry)
        reconcileClassifierTypes()
        return entry
    }

    /// Moves a collection platform and its collected entries into a trash snapshot,
    /// reusing the vetted `removePlatformBinding` cascade for removal.
    @discardableResult
    public mutating func trashCollectionPlatform(_ platformID: String) -> TrashedEntry? {
        guard let binding = bindings.first(where: { $0.id == platformID }) else { return nil }
        let capturedEntries = datasets.flatMap { $0.collectedEntries.filter { $0.platformID == platformID } }
        guard removePlatformBinding(platformID) else { return nil }
        let entry = TrashedEntry(
            kind: .collectionPlatform,
            name: binding.name,
            binding: binding,
            datasetID: binding.datasetID,
            collectedEntries: capturedEntries
        )
        trash.append(entry)
        return entry
    }

    /// Moves an unreferenced tag tree into trash. A tree still referenced by any
    /// classifier type or platform binding cannot be trashed; the caller must
    /// remove those dependents first.
    @discardableResult
    public mutating func trashTagTree(_ treeID: String) throws -> TrashedEntry? {
        guard let index = trees.firstIndex(where: { $0.id == treeID }) else { return nil }
        if bindings.contains(where: { $0.treeID == treeID }) || classifierTypes.contains(where: { $0.treeID == treeID }) {
            throw WorkspaceCatalogError.treeInUse(treeID)
        }
        let tree = trees.remove(at: index)
        let entry = TrashedEntry(kind: .tagTree, name: tree.name, tree: tree)
        trash.append(entry)
        return entry
    }

    /// Re-inserts a trashed entry and every dependent configuration it captured.
    @discardableResult
    public mutating func restoreTrashedEntry(_ id: String) -> Bool {
        guard let index = trash.firstIndex(where: { $0.id == id }) else { return false }
        let entry = trash.remove(at: index)
        switch entry.kind {
        case .classifierType:
            guard let type = entry.classifierType, !classifierTypes.contains(where: { $0.id == type.id }) else { break }
            classifierTypes.append(type)
        case .collectionPlatform:
            guard let binding = entry.binding else { break }
            if !bindings.contains(where: { $0.id == binding.id }) { bindings.append(binding) }
            if let datasetID = entry.datasetID, let dIndex = datasets.firstIndex(where: { $0.id == datasetID }) {
                datasets[dIndex].collectedEntries.append(contentsOf: entry.collectedEntries)
            }
        case .tagTree:
            guard let tree = entry.tree, !trees.contains(where: { $0.id == tree.id }) else { break }
            trees.append(tree)
        }
        reconcileClassifierTypes()
        return true
    }

    @discardableResult
    public mutating func permanentlyDeleteTrashedEntry(_ id: String) -> Bool {
        guard let index = trash.firstIndex(where: { $0.id == id }) else { return false }
        trash.remove(at: index)
        return true
    }

    /// Opportunistic purge: removes trash entries whose lifetime has elapsed.
    /// Called on catalog load and trash interactions rather than on a timer.
    @discardableResult
    public mutating func purgeExpiredTrash(
        nowMilliseconds: Int64 = WorkspaceCatalog.now(),
        ttlMilliseconds: Int64 = TrashedEntry.defaultTTLMilliseconds
    ) -> Int {
        let before = trash.count
        trash.removeAll { nowMilliseconds - $0.deletedAtMilliseconds >= ttlMilliseconds }
        return before - trash.count
    }

    /// Keep classifier types aligned with their current tree and data revisions.
    public mutating func reconcileClassifierTypes() {
        for index in trees.indices {
            TagColorAssignment.reconcileColors(in: &trees[index])
        }
        providerProfiles = providerProfiles.filter { (try? $0.validate()) != nil }
        classifierTypes = classifierTypes.compactMap { classifierType in
            guard let tree = trees.first(where: { $0.id == classifierType.treeID }),
                  let dataset = datasets.first(where: { $0.id == classifierType.datasetID }) else {
                return nil
            }
            var reconciled = classifierType
            reconciled.treeRevision = tree.revision
            reconciled.datasetRevision = dataset.revision
            // A type owns its own tree now; the binding only supplies the shared
            // dataset and the platform. Do not require the binding to hold the
            // type's tree (that would orphan the platform on every reconcile).
            let applicableBinding = reconciled.applicablePlatformID.flatMap { platformID in
                bindings.first(where: { binding in
                    binding.id == platformID && binding.datasetID == dataset.id
                })
            }
            reconciled.applicablePlatformID = applicableBinding?.id
            reconciled.updatedAtMilliseconds = WorkspaceCatalog.now()
            return reconciled
        }
        for index in bindings.indices {
            // Auto-select the sole compatible classifier type for the platform.
            // Ambiguity (zero or several compatible types) leaves the choice to
            // the owner.
            if bindings[index].activeClassifierTypeID == nil,
               let tree = trees.first(where: { $0.id == bindings[index].treeID }),
               let dataset = datasets.first(where: { $0.id == bindings[index].datasetID }) {
                let compatible = classifierTypes.filter { candidate in
                    guard candidate.applicablePlatformID == bindings[index].id,
                          candidate.treeID == tree.id,
                          candidate.treeRevision == tree.revision,
                          candidate.datasetID == dataset.id,
                          candidate.datasetRevision == dataset.revision else {
                        return false
                    }
                    return true
                }
                if compatible.count == 1 {
                    bindings[index].activeClassifierTypeID = compatible[0].id
                }
            }
            guard let classifierTypeID = bindings[index].activeClassifierTypeID else { continue }
            guard let classifierType = classifierTypes.first(where: { $0.id == classifierTypeID }),
                  let tree = trees.first(where: { $0.id == bindings[index].treeID }),
                  let dataset = datasets.first(where: { $0.id == bindings[index].datasetID }),
                  classifierType.treeID == tree.id,
                  classifierType.treeRevision == tree.revision,
                  classifierType.datasetID == dataset.id,
                  classifierType.datasetRevision == dataset.revision,
                  classifierType.applicablePlatformID == bindings[index].id else {
                bindings[index].activeClassifierTypeID = nil
                continue
            }
        }
    }
}
