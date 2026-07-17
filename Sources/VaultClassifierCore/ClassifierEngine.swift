import Foundation

public enum ClassifierEngineError: Error, LocalizedError, Sendable {
    case invalidEvidence(EntryEvidenceValidationError)

    public var errorDescription: String? {
        switch self { case .invalidEvidence(let error): return error.localizedDescription }
    }
}

public struct LocalClassifierEngine: Sendable {
    public let package: SeedModelPackage
    public let taxonomy: Taxonomy
    public var policies: [NamedPolicy]
    public var sourceProfiles: [String: SourceProfile]
    public var personalModel: PersonalFTRLModel
    public var sequence: Int64
    public var settings: ClassifierSettings

    public init(verifiedPackage: VerifiedSeedPackage, policies: [NamedPolicy] = [], sourceProfiles: [String: SourceProfile] = [:], personalModel: PersonalFTRLModel = .init(), sequence: Int64 = 0, settings: ClassifierSettings = .init()) throws {
        self.package = verifiedPackage.package
        self.taxonomy = try verifiedPackage.taxonomy
        self.policies = policies
        self.sourceProfiles = sourceProfiles
        self.personalModel = personalModel
        self.sequence = sequence
        self.settings = settings
    }

    /// `recordSourceObservation` is normally true. The explicit cache backfill
    /// coordinator temporarily disables it for ordinary foreground entries
    /// while it is replaying FIFO cache evidence, then replays those entries
    /// in order. This prevents a newer foreground item from becoming a prior
    /// for an older pending cache row.
    public mutating func classify(_ entry: EntryEvidence, recordSourceObservation: Bool = true) throws -> ClassificationResult {
        do { try EntryEvidenceValidator().validate(entry) }
        catch let error as EntryEvidenceValidationError { throw ClassifierEngineError.invalidEvidence(error) }

        sequence += 1
        let features = NgramFeatures.features(for: entry.evidence)
        let threshold = package.threshold(for: entry.surface)
        let evidenceState: ClassificationEvidenceState = (entry.evidence.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || entry.evidence.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? .sufficient : .limited
        let allowedTags = taxonomy.predictableLeafIDs.sorted()
        let sourcePrior = entry.sourceID.flatMap { sourceProfiles[$0]?.scores(at: sequence, halfLifeEntries: package.sourcePrior.halfLifeEntries) }
        let sourceWeight = package.sourcePrior.effectiveWeight(for: sourcePrior?.effectiveCount ?? 0)
        var tagScores: [TagScore] = []

        for tagID in allowedTags {
            let baseLogit = package.model.logit(for: tagID, features: features)
            let directScore = sigmoid(baseLogit + personalModel.logitDelta(for: tagID, features: features))
            let canUseSource = taxonomy.isDescendant(tagID, of: "content.topics") || taxonomy.isDescendant(tagID, of: "content.entities")
            let sourceScore = canUseSource ? sourcePrior?.scores[tagID] : nil
            let finalScore: Double
            if let sourceScore {
                finalScore = directScore * (1 - sourceWeight) + sourceScore * sourceWeight
            } else {
                finalScore = directScore
            }
            tagScores.append(.init(tagID: tagID, directScore: directScore, sourceScore: sourceScore, finalScore: finalScore))
        }
        tagScores.sort { $0.finalScore == $1.finalScore ? $0.tagID < $1.tagID : $0.finalScore > $1.finalScore }
        let selected = tagScores.filter { $0.finalScore >= threshold }.map(\.tagID)
        let ancestors = taxonomy.ancestorClosure(for: selected)
        var result = ClassificationResult(
            entryID: entry.entryID,
            sourceID: entry.sourceID,
            surface: entry.surface,
            evidenceState: evidenceState,
            threshold: threshold,
            selectedLeafTagIDs: selected,
            ancestorTagIDs: ancestors,
            scores: tagScores,
            decisions: [],
            packageID: package.packageID,
            modelVersion: package.modelVersion
        )
        result.decisions = PolicyEvaluator(taxonomy: taxonomy).evaluate(result: result, policies: policies, requestedPolicyIDs: entry.policyIDs)

        // The just-classified item is deliberately added only after scoring, and only when
        // direct evidence was strong. This prevents a vague target title from boosting itself.
        if recordSourceObservation, evidenceState == .sufficient, let sourceID = entry.sourceID {
            let strongSignals = Dictionary(uniqueKeysWithValues: tagScores.compactMap { score -> (String, Double)? in
                guard score.directScore >= max(threshold, 0.70),
                      taxonomy.isDescendant(score.tagID, of: "content.topics") || taxonomy.isDescendant(score.tagID, of: "content.entities") else { return nil }
                return (score.tagID, score.directScore)
            })
            if !strongSignals.isEmpty {
                var profile = sourceProfiles[sourceID] ?? .init()
                profile.append(sequence: sequence, leafScores: strongSignals, limit: settings.resourceProfile.sourceObservationLimit)
                sourceProfiles[sourceID] = profile
            }
        }
        return result
    }

    public mutating func trainLocalCorrection(for tagID: String, isPositive: Bool, evidence: EntryEvidence) throws {
        guard taxonomy.predictableLeafIDs.contains(tagID) else { return }
        try EntryEvidenceValidator().validate(evidence)
        let features = NgramFeatures.features(for: evidence.evidence)
        personalModel.train(features: features, tagID: tagID, isPositive: isPositive, baseLogit: package.model.logit(for: tagID, features: features))
    }

    /// Rebuilds the per-installation correction layer from explicit retained
    /// labels. The base package is never edited; this is a deterministic local
    /// overlay that can be regenerated whenever a person adds or corrects a
    /// label.
    public mutating func rebuildPersonalModel(
        from examples: [LocalTrainingExample],
        epochs: Int
    ) throws -> (exampleCount: Int, labelUpdateCount: Int) {
        guard (1...12).contains(epochs) else { throw LocalTrainingError.invalidEpochCount }
        let leaves = taxonomy.predictableLeafIDs
        let compatible = examples
            .filter { $0.taxonomyVersion == package.taxonomyVersion }
            .map { example in
                var copy = example
                copy.positiveLeafTagIDs = example.positiveLeafTagIDs.filter(leaves.contains).sorted()
                copy.negativeLeafTagIDs = example.negativeLeafTagIDs.filter(leaves.contains).sorted()
                return copy
            }
            .filter { !$0.positiveLeafTagIDs.isEmpty || !$0.negativeLeafTagIDs.isEmpty }
            .sorted {
                if $0.createdAtMilliseconds != $1.createdAtMilliseconds {
                    return $0.createdAtMilliseconds < $1.createdAtMilliseconds
                }
                return $0.cacheKey < $1.cacheKey
            }
        guard !compatible.isEmpty else { throw LocalTrainingError.noCompatibleExamples }

        var replacement = PersonalFTRLModel(settings: personalModel.settings)
        var labelUpdateCount = 0
        for _ in 0..<epochs {
            for example in compatible {
                let features = NgramFeatures.features(for: example.evidence.evidence)
                for tagID in example.positiveLeafTagIDs {
                    replacement.train(
                        features: features,
                        tagID: tagID,
                        isPositive: true,
                        baseLogit: package.model.logit(for: tagID, features: features)
                    )
                    labelUpdateCount += 1
                }
                for tagID in example.negativeLeafTagIDs {
                    replacement.train(
                        features: features,
                        tagID: tagID,
                        isPositive: false,
                        baseLogit: package.model.logit(for: tagID, features: features)
                    )
                    labelUpdateCount += 1
                }
            }
        }
        personalModel = replacement
        return (compatible.count, labelUpdateCount)
    }
}
