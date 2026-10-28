#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// Collection and corrections: platform entry intake, collection metadata, enabled platform set, human corrections and the entries they affect.
// Split out of LocalStore.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour.
extension LocalClassifierCoordinator {
    public func enabledCollectionPlatformIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return state.workspaceCatalog.bindings.filter(\.collectionEnabled).map(\.id).sorted()
    }

    public func hasClassifierTypes(platformID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.workspaceCatalog.classifierTypes.contains { $0.applicablePlatformIDs.contains(platformID) }
    }

    /// The native Classifier owns activation; browser blocking schedules do not.
    public func enabledClassificationPlatformIDs() -> [String] {
        lock.withLock {
            guard state.settings.classificationEnabled else { return [] }
            let recording = Set(state.workspaceCatalog.bindings.filter(\.collectionEnabled).map(\.id))
            return Set(state.workspaceCatalog.classifierTypes.filter { !$0.isPaused }
                .flatMap(\.applicablePlatformIDs)).intersection(recording).sorted()
        }
    }

    /// Stores an authoritative human correction and updates the cached
    /// projection. A correction never schedules research: research is driven by
    /// the model's own uncertainty (derived urgency), and a human-corrected video
    /// has none left (the former `correctionsOnly`/`all` trigger modes are gone).
    @discardableResult
    public func submitCorrection(
        classifierTypeID: String,
        platformID: String,
        entryID: String,
        correctTagIDs: [String],
        note: String? = nil
    ) throws -> VideoTagsProjection {
        let saved = try lock.withLock { () throws -> (
            projection: VideoTagsProjection,
            callback: (@Sendable (String, String, VideoTagsProjection) -> Void)?
        ) in
            guard let typeIndex = state.workspaceCatalog.classifierTypes.firstIndex(where: {
                $0.id == classifierTypeID && $0.applicablePlatformIDs.contains(platformID)
            }) else { throw CorrectionSubmissionError.invalidClassifierType }
            let type = state.workspaceCatalog.classifierTypes[typeIndex]
            guard let tree = state.workspaceCatalog.trees.first(where: {
                $0.id == type.treeID && $0.revision == type.treeRevision
            }) else { throw CorrectionSubmissionError.invalidClassifierType }
            guard let entry = Self.collectedEntry(
                platformID: platformID,
                entryID: entryID,
                catalog: state.workspaceCatalog
            ) else { throw CorrectionSubmissionError.missingCollectedEntry }
            let taxonomy = try tree.inferenceTaxonomy()
            let uniqueTagIDs = Array(Set(correctTagIDs)).sorted()
            guard uniqueTagIDs.count <= CorrectionExample.maximumTagIDs,
                  uniqueTagIDs.allSatisfy({ taxonomy.nodes[$0]?.predictable == true }) else {
                throw CorrectionSubmissionError.invalidTagSelection
            }

            let example = CorrectionExample(
                classifierTypeID: classifierTypeID,
                platformID: platformID,
                entryID: entryID,
                creatorID: entry.creatorID,
                title: entry.title,
                correctTagIDs: uniqueTagIDs,
                note: note
            )
            state.workspaceCatalog.appendCorrectionExample(example)
            // This video's correction remains authoritative. For future uncached
            // items in the same group, the prompt may include a few relevant
            // corrected titles and final tags as examples. Notes stay private,
            // and manual house rules are unchanged.

            let previous = state.workspaceCatalog.videoClassification(
                classifierTypeID: classifierTypeID,
                platformID: platformID,
                entryID: entryID
            )
            state.workspaceCatalog.upsertVideoClassification(.init(
                id: previous?.id ?? UUID().uuidString,
                classifierTypeID: classifierTypeID,
                platformID: platformID,
                entryID: entryID,
                creatorID: entry.creatorID,
                treeID: tree.id,
                treeRevision: tree.revision,
                tags: uniqueTagIDs.map { .init(tagID: $0, confidence: ScoredTag.maxConfidence) },
                source: .humanCorrected,
                modelVersion: previous?.modelVersion ?? "human-correction-v1",
                createdAtMilliseconds: previous?.createdAtMilliseconds ?? WorkspaceCatalog.now()
            ))
            try stateFile.save(state)
            let types = Self.orderedTypes(for: platformID, in: state.workspaceCatalog)
            return (
                Self.videoTagsProjection(
                    entryID: entryID,
                    platformID: platformID,
                    types: types,
                    catalog: state.workspaceCatalog
                ),
                onVideoReclassifiedCallback
            )
        }

        saved.callback?(platformID, entryID, saved.projection)
        // Corrections are authoritative tags for their own video only; they are
        // not surfaced to the classifier at all (measured as noise), and never by a
        // local-LLM free-text "re-summary" — a small model asked to generalize a
        // handful of corrections fabricates spurious rules ("tag Samsung as
        // Sports") that poison classification. Grounded exemplars beat invented
        // framing; see the creator prior for the same lesson.
        return saved.projection
    }

    static func collectedEntry(
        platformID: String,
        entryID: String,
        catalog: WorkspaceCatalog
    ) -> CollectedPlatformEntry? {
        catalog.datasets.lazy.flatMap(\.collectedEntries).first {
            $0.platformID == platformID && $0.entryID == entryID
        }
    }


    @discardableResult
    public func collectPlatformEntry(
        _ entry: EntryEvidence,
        firstObservedAtMilliseconds requestedFirstObservedAtMilliseconds: Int64? = nil,
        lastObservedAtMilliseconds requestedLastObservedAtMilliseconds: Int64? = nil,
        observationCount requestedObservationCount: Int? = nil,
        at milliseconds: Int64 = WorkspaceCatalog.now()
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        try EntryEvidenceValidator().validate(entry)
        guard let binding = state.workspaceCatalog.bindings.first(where: { $0.id == entry.platform }),
              binding.collectionEnabled else { throw PlatformCollectionError.disabled(entry.platform) }
        guard let entryID = entry.entryID?.trimmingCharacters(in: .whitespacesAndNewlines), !entryID.isEmpty else {
            throw PlatformCollectionError.missingEntryIdentifier
        }
        guard let creatorID = entry.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !creatorID.isEmpty else {
            throw PlatformCollectionError.missingCreatorIdentifier
        }
        guard let title = entry.evidence.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw PlatformCollectionError.missingTitle
        }

        let metadata = collectionMetadata(from: entry.evidence.metadata, platformID: entry.platform)
        guard metadata["isAdvertisement"] != "true" else { throw PlatformCollectionError.advertisement }
        let entryType = metadata["entryType"]?.lowercased() ?? "content"
        guard entryType != "advertisement", entryType != "ad" else { throw PlatformCollectionError.advertisement }
        let creatorName = metadata["sourceName"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalURL = metadata["canonicalURL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIconURL = metadata["sourceIconURL"].flatMap {
            SourceIconURLPolicy.isAccepted(platformID: entry.platform, value: $0) ? $0 : nil
        }
        let maximumFutureTimestamp = milliseconds + (5 * 60 * 1_000)
        let firstObservedAtMilliseconds = requestedFirstObservedAtMilliseconds.flatMap {
            $0 > 0 && $0 <= maximumFutureTimestamp ? $0 : nil
        } ?? milliseconds
        let lastObservedAtMilliseconds = max(
            firstObservedAtMilliseconds,
            requestedLastObservedAtMilliseconds.flatMap {
                $0 > 0 && $0 <= maximumFutureTimestamp ? $0 : nil
            } ?? firstObservedAtMilliseconds
        )
        let observationCount = min(512, max(1, requestedObservationCount ?? 1))
        let stableMaterial = "\(entry.platform)\u{1F}\(entryID)"
        let stableID = SHA256.hash(data: Data(stableMaterial.utf8)).map { String(format: "%02x", $0) }.joined()
        let collected = CollectedPlatformEntry(
            id: "collected-\(stableID)",
            platformID: entry.platform,
            entryID: entryID,
            creatorID: creatorID,
            sourceAliases: entry.sourceAliases,
            creatorName: creatorName?.isEmpty == false ? creatorName! : creatorID,
            entryType: entryType,
            title: title,
            surface: entry.surface,
            text: entry.evidence.text,
            summary: entry.evidence.summary,
            suppliedTags: entry.evidence.suppliedTags,
            canonicalURL: canonicalURL?.isEmpty == false ? canonicalURL : nil,
            sourceIconURL: sourceIconURL,
            attributes: metadata.filter {
                key, _ in
                key != "sourceName" && key != "canonicalURL" && key != "entryType" &&
                    key != "isAdvertisement" && key != "sourceIconURL"
            },
            firstObservedAtMilliseconds: firstObservedAtMilliseconds,
            lastObservedAtMilliseconds: lastObservedAtMilliseconds,
            observationCount: observationCount
        )
        guard let datasetIndex = state.workspaceCatalog.datasets.firstIndex(where: { $0.id == binding.datasetID }) else {
            throw WorkspaceCatalogError.missingDataset(binding.datasetID)
        }
        guard WorkspaceCatalog.isValidCollectedEntry(collected) else {
            throw WorkspaceCatalogError.invalidCollectedEntry(collected.id)
        }
        let inserted = state.workspaceCatalog.datasets[datasetIndex].upsertCollectedEntry(collected)
        // Each platform's Keep, applied at most hourly while collecting.
        let now = WorkspaceCatalog.now()
        if now - lastCollectionPrune > 3_600_000 {
            lastCollectionPrune = now
            state.workspaceCatalog.pruneCollectedEntries(nowMilliseconds: now)
        }
        try stateFile.save(state)
        return inserted
    }

    func collectionMetadata(from metadata: [String: JSONValue], platformID: String) -> [String: String] {
        var output: [String: String] = [:]
        for key in metadata.keys.sorted() {
            guard key != "creatorAvatarURL", key != "creatorURL" else { continue }
            guard output.count < CollectedPlatformEntry.maximumAttributes + 4,
                  key.count <= CollectedPlatformEntry.maximumAttributeKeyLength,
                  let value = metadata[key] else { continue }
            let rendered: String
            switch value {
            case .string(let text): rendered = text
            case .number(let number): rendered = number.formatted(.number.grouping(.never))
            case .bool(let bool): rendered = bool ? "true" : "false"
            }
            guard !rendered.isEmpty, rendered.count <= CollectedPlatformEntry.maximumAttributeValueLength else { continue }
            if key == "sourceIconURL", !SourceIconURLPolicy.isAccepted(platformID: platformID, value: rendered) {
                continue
            }
            // Thumbnail URLs were only ever accepted for the retired OCR evidence.
            if key == "thumbnailURL" { continue }
            output[key] = rendered
        }
        return output
    }
}
