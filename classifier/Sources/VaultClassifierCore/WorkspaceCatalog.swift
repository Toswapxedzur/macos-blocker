import Foundation

// The aggregate root of all authored + collected workspace state, its validation and histograms.
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
    case duplicateApplicablePlatform(String)

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
        case .duplicateApplicablePlatform(let value): return "That platform is already assigned to another classifier type: \(value). A platform can belong to only one type."
        }
    }
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
    /// Days to keep collected entries on every platform that doesn't set its
    /// own Keep (`PlatformBinding.collectionKeepDays`); 0 = forever. Default
    /// 365 (owner 2026-09-30; it follows Activity's "Keep all history").
    public var collectionKeepDays: Int = 365

    public init(trees: [TagTreeAsset] = [], datasets: [ClassificationDataset] = [], bindings: [PlatformBinding] = [], classifierTypes: [ClassifierTypeAsset] = [], tokenUsage: [TokenUsageRecord] = [], providerRequestRecords: [ProviderRequestRecord] = [], providerProfiles: [APIKeyProviderProfile] = [], videoClassifications: [VideoClassification] = [], knowledgeEntries: [KnowledgeEntry] = [], creatorKnowledge: [KnowledgeEntry] = [], researchAttempts: [ResearchAttemptRecord] = [], correctionExamples: [CorrectionExample] = [], creatorHistograms: [CreatorTagHistogram] = [], creatorResearchAccumulators: [CreatorResearchAccumulator] = []) {
        self.trees = trees
        self.datasets = datasets
        self.bindings = bindings
        self.classifierTypes = classifierTypes
        self.tokenUsage = tokenUsage
        self.providerRequestRecords = providerRequestRecords
        self.providerProfiles = providerProfiles
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
        // Every platform that classifies is collected by default; the others
        // only when the person turns them on (owner 2026-09-30). Bindings share the local
        // dataset (entries self-tag with their platform); classifier types own
        // their own trees, so the shared starter tree is only the binding anchor.
        let bindings = CollectionPlatformRegistry.definitions.map { definition in
            PlatformBinding(
                id: definition.id,
                name: definition.name,
                browser: definition.browser,
                treeID: tree.id,
                datasetID: dataset.id,
                collectionEnabled: definition.supportsLocalModel
            )
        }
        return .init(trees: [tree], datasets: [dataset], bindings: bindings)
    }

    /// One collected entry's shape (the collect path checks only the entry it
    /// adds; `validate` checks them all).
    public static func isValidCollectedEntry(_ entry: CollectedPlatformEntry) -> Bool {
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
              entry.observationCount > 0 else { return false }
        return true
    }

    /// Drops collected entries past their platform's Keep (by when last seen)
    /// and, per platform, the oldest beyond the safety bound. Returns whether
    /// anything went.
    @discardableResult
    public mutating func pruneCollectedEntries(nowMilliseconds: Int64 = WorkspaceCatalog.now()) -> Bool {
        var cutoffs: [String: Int64] = [:]
        for binding in bindings {
            let days = binding.collectionKeepDays >= 0 ? binding.collectionKeepDays : collectionKeepDays
            if days > 0 { cutoffs[binding.id] = nowMilliseconds - Int64(days) * 86_400_000 }
        }
        var changed = false
        for index in datasets.indices {
            let before = datasets[index].collectedEntries.count
            datasets[index].collectedEntries.removeAll { entry in
                cutoffs[entry.platformID].map { entry.lastObservedAtMilliseconds < $0 } ?? false
            }
            let counts = Dictionary(grouping: datasets[index].collectedEntries, by: \.platformID).mapValues(\.count)
            for (platformID, count) in counts where count > CollectedPlatformEntry.maximumEntriesPerPlatform {
                let cutoff = datasets[index].collectedEntries
                    .filter { $0.platformID == platformID }
                    .map(\.lastObservedAtMilliseconds)
                    .sorted(by: >)[CollectedPlatformEntry.maximumEntriesPerPlatform - 1]
                datasets[index].collectedEntries.removeAll { $0.platformID == platformID && $0.lastObservedAtMilliseconds < cutoff }
            }
            if datasets[index].collectedEntries.count != before { changed = true }
        }
        return changed
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
        // A platform belongs to at most one classifier type. The classify path
        // runs EVERY type whose applicablePlatformIDs hold it, so two types on
        // one platform silently double all engine work. (One type may hold
        // several platforms, owner 2026-09-30.)
        var claimedPlatforms = Set<String>()
        for classifierType in classifierTypes {
            for platformID in classifierType.applicablePlatformIDs {
                guard claimedPlatforms.insert(platformID).inserted else {
                    throw WorkspaceCatalogError.duplicateApplicablePlatform(platformID)
                }
            }
        }
        for dataset in datasets {
            var seenEntries = Set<String>()
            for entry in dataset.collectedEntries {
                guard Self.isValidCollectedEntry(entry),
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
                  classifierType.applicablePlatformIDs.allSatisfy({ platformID in
                      // Each of the type's platforms: a binding on the shared dataset.
                      platformID.count <= 64 && bindings.contains(where: { binding in
                          binding.id == platformID && binding.datasetID == dataset.id
                      })
                  }) else {
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
                  classifierType.applicablePlatformIDs.contains(binding.id),
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
        case trees, datasets, bindings, classifierTypes, tokenUsage, providerRequestRecords, providerProfiles,
             videoClassifications, knowledgeEntries, creatorKnowledge, researchAttempts, correctionExamples, creatorHistograms,
             creatorResearchAccumulators, collectionKeepDays
    }


    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trees = try container.decodeIfPresent([TagTreeAsset].self, forKey: .trees) ?? []
        datasets = try container.decodeIfPresent([ClassificationDataset].self, forKey: .datasets) ?? []
        bindings = try container.decodeIfPresent([PlatformBinding].self, forKey: .bindings) ?? []
        classifierTypes = try container.decodeIfPresent([ClassifierTypeAsset].self, forKey: .classifierTypes) ?? []
        tokenUsage = try container.decodeIfPresent([TokenUsageRecord].self, forKey: .tokenUsage) ?? []
        providerRequestRecords = try container.decodeIfPresent([ProviderRequestRecord].self, forKey: .providerRequestRecords) ?? []
        providerProfiles = try container.decodeIfPresent([APIKeyProviderProfile].self, forKey: .providerProfiles) ?? []
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
        // Rows of the retired sample-list rule decode with an empty score: drop them.
        creatorResearchAccumulators = (try container.decodeIfPresent([CreatorResearchAccumulator].self, forKey: .creatorResearchAccumulators) ?? [])
            .filter { $0.score > 0 }
        collectionKeepDays = max(0, try container.decodeIfPresent(Int.self, forKey: .collectionKeepDays) ?? 365)
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
            collectionEnabled: definition.supportsLocalModel
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

    /// Permanently removes a classifier group and releases its platform claims.
    /// Shared collection bindings and their data stay available.
    @discardableResult
    public mutating func removeClassifierType(_ typeID: String) -> Bool {
        guard let index = classifierTypes.firstIndex(where: { $0.id == typeID }) else { return false }
        classifierTypes.remove(at: index)
        for bindingIndex in bindings.indices where bindings[bindingIndex].activeClassifierTypeID == typeID {
            bindings[bindingIndex].activeClassifierTypeID = nil
        }
        reconcileClassifierTypes()
        return true
    }

    /// Permanently clears a platform's collected entries, retaining its binding
    /// and the classifier group that uses it.
    @discardableResult
    public mutating func clearCollectedEntries(_ platformID: String) -> Bool {
        guard bindings.contains(where: { $0.id == platformID }) else { return false }
        for index in datasets.indices {
            datasets[index].collectedEntries.removeAll { $0.platformID == platformID }
        }
        return true
    }

    /// Keep classifier types aligned with their current tree and data revisions.
    public mutating func reconcileClassifierTypes() {
        // A platform the classifier no longer supports (TikTok, deleted
        // 2026-09-24) leaves the stored catalog — its binding and collected
        // entries go; a type aimed at it stays, unbound (below). A stored state
        // must never keep the classifier from starting.
        let supported = { (platformID: String) in CollectionPlatformRegistry.definition(for: platformID) != nil }
        bindings.removeAll { !supported($0.id) }
        for index in datasets.indices {
            datasets[index].collectedEntries.removeAll { !supported($0.platformID) }
        }
        // Drop trees as soon as their last group or binding is removed.
        let usedTrees = Set(classifierTypes.map(\.treeID) + bindings.map(\.treeID))
        trees.removeAll { !usedTrees.contains($0.id) }
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
            reconciled.applicablePlatformIDs = reconciled.applicablePlatformIDs.filter { platformID in
                bindings.contains(where: { binding in
                    binding.id == platformID && binding.datasetID == dataset.id
                })
            }
            reconciled.updatedAtMilliseconds = WorkspaceCatalog.now()
            return reconciled
        }
        // Invariant: a platform is claimed by at most one classifier type (the
        // classify path runs every matching type, so duplicates double the
        // engine work). Resolve stale duplicates by UNBINDING the extras — never
        // deleting a type: the binding's chosen active type wins, else the first.
        // Deliberate duplicate assignments are refused earlier, at the write path.
        for platformID in Set(classifierTypes.flatMap(\.applicablePlatformIDs)) {
            let claimants = classifierTypes.indices.filter { classifierTypes[$0].applicablePlatformIDs.contains(platformID) }
            guard claimants.count > 1 else { continue }
            let activeID = bindings.first(where: { $0.id == platformID })?.activeClassifierTypeID
            let winner = claimants.first(where: { classifierTypes[$0].id == activeID }) ?? claimants[0]
            for index in claimants where index != winner {
                classifierTypes[index].applicablePlatformIDs.removeAll { $0 == platformID }
            }
        }
        for index in bindings.indices {
            // Auto-select the sole compatible classifier type for the platform.
            // Ambiguity (zero or several compatible types) leaves the choice to
            // the owner.
            if bindings[index].activeClassifierTypeID == nil,
               let tree = trees.first(where: { $0.id == bindings[index].treeID }),
               let dataset = datasets.first(where: { $0.id == bindings[index].datasetID }) {
                let compatible = classifierTypes.filter { candidate in
                    guard candidate.applicablePlatformIDs.contains(bindings[index].id),
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
                  classifierType.applicablePlatformIDs.contains(bindings[index].id) else {
                bindings[index].activeClassifierTypeID = nil
                continue
            }
        }
    }
}
