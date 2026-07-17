import Foundation

/// A compact local-only tokenizer for the embedding model. The vocabulary is
/// deliberately derived from approved training text; it neither downloads nor
/// imports a remote language model.
public struct LocalEmbeddingVocabulary: Codable, Equatable, Sendable {
    public static let unknownToken = "<unk>"

    /// Index zero is always the unknown-token embedding.
    public var tokens: [String]

    public init(tokens: [String]) {
        var unique = Set<String>()
        let normalized = tokens.compactMap { token -> String? in
            let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned != Self.unknownToken, unique.insert(cleaned).inserted else { return nil }
            return cleaned
        }
        self.tokens = [Self.unknownToken] + normalized
    }

    public static func build(from examples: [EmbeddedNeuralTrainingExample], limit: Int) -> LocalEmbeddingVocabulary {
        var frequencies: [String: Int] = [:]
        for example in examples {
            for token in tokenize(example.text) {
                frequencies[token, default: 0] += 1
            }
        }
        let retained = frequencies.keys.sorted { left, right in
            let leftFrequency = frequencies[left] ?? 0
            let rightFrequency = frequencies[right] ?? 0
            if leftFrequency != rightFrequency { return leftFrequency > rightFrequency }
            return left < right
        }
        return .init(tokens: Array(retained.prefix(max(0, limit - 1))))
    }

    public func tokenIDs(for text: String) -> [Int] {
        let positions = Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($0.element, $0.offset) })
        let values = Self.tokenize(text).map { positions[$0] ?? 0 }
        return values.isEmpty ? [0] : values
    }

    public static func tokenize(_ text: String) -> [String] {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in token.count >= 2 && token.count <= 64 }
    }
}

/// A supervised sample for the on-device embedding encoder and neural head.
/// Unlisted labels are not assumed to be negative; only explicit labels create
/// a loss term, which avoids learning from ambiguous browsing text.
public struct EmbeddedNeuralTrainingExample: Codable, Equatable, Sendable {
    public var text: String
    public var positiveLabelIDs: [String]
    public var negativeLabelIDs: [String]

    public init(text: String, positiveLabelIDs: [String], negativeLabelIDs: [String] = []) {
        self.text = text
        self.positiveLabelIDs = Array(Set(positiveLabelIDs)).sorted()
        self.negativeLabelIDs = Array(Set(negativeLabelIDs)).sorted()
    }
}

public struct EmbeddedNeuralModelConfiguration: Codable, Equatable, Sendable {
    public var vocabularyLimit: Int
    public var embeddingDimension: Int
    public var hiddenDimension: Int
    public var learningRate: Double
    public var l2Penalty: Double
    public var initializationSeed: UInt64

    public init(
        vocabularyLimit: Int = 2_048,
        embeddingDimension: Int = 48,
        hiddenDimension: Int = 32,
        learningRate: Double = 0.08,
        l2Penalty: Double = 0.0001,
        initializationSeed: UInt64 = 0xC0DEC0DE
    ) {
        self.vocabularyLimit = vocabularyLimit
        self.embeddingDimension = embeddingDimension
        self.hiddenDimension = hiddenDimension
        self.learningRate = learningRate
        self.l2Penalty = l2Penalty
        self.initializationSeed = initializationSeed
    }
}

public struct EmbeddedNeuralPrediction: Codable, Equatable, Sendable {
    public var labelID: String
    public var probability: Double

    public init(labelID: String, probability: Double) {
        self.labelID = labelID
        self.probability = probability
    }
}

public struct EmbeddedNeuralTrainingReport: Codable, Equatable, Sendable {
    public var epochs: Int
    public var exampleCount: Int
    public var labelUpdateCount: Int
    public var meanBinaryCrossEntropy: Double

    public init(epochs: Int, exampleCount: Int, labelUpdateCount: Int, meanBinaryCrossEntropy: Double) {
        self.epochs = epochs
        self.exampleCount = exampleCount
        self.labelUpdateCount = labelUpdateCount
        self.meanBinaryCrossEntropy = meanBinaryCrossEntropy
    }
}

public enum EmbeddedNeuralModelError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case emptyLabelSet
    case duplicateLabelID(String)
    case unknownLabelID(String)
    case overlappingLabels(String)
    case invalidEpochCount
    case noExplicitLabels

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The local embedding model configuration is invalid."
        case .emptyLabelSet:
            return "A neural classifier needs at least one label."
        case .duplicateLabelID(let labelID):
            return "The local neural model repeats label \(labelID)."
        case .unknownLabelID(let labelID):
            return "The local neural model does not know label \(labelID)."
        case .overlappingLabels(let labelID):
            return "Label \(labelID) cannot be both positive and negative."
        case .invalidEpochCount:
            return "Neural training needs at least one epoch."
        case .noExplicitLabels:
            return "Neural training needs at least one explicit label."
        }
    }
}

/// A small trainable text-embedding encoder followed by a multi-label neural
/// classifier. It is intentionally self-contained: input text is tokenized,
/// embedded, mean pooled, projected through ReLU, then scored by sigmoid heads.
/// It never contacts a server; local model panels persist it only after an
/// explicit user-initiated training run.
public struct EmbeddedNeuralTextClassifier: Codable, Equatable, Sendable {
    public var configuration: EmbeddedNeuralModelConfiguration
    public var vocabulary: LocalEmbeddingVocabulary
    public var labelIDs: [String]
    public private(set) var tokenEmbeddings: [[Double]]
    public private(set) var projectionWeights: [[Double]]
    public private(set) var projectionBiases: [Double]
    public private(set) var outputWeights: [[Double]]
    public private(set) var outputBiases: [Double]

    public init(
        configuration: EmbeddedNeuralModelConfiguration = .init(),
        labelIDs: [String],
        vocabulary: LocalEmbeddingVocabulary
    ) throws {
        try Self.validate(configuration: configuration, labelIDs: labelIDs)
        self.configuration = configuration
        self.vocabulary = vocabulary
        self.labelIDs = labelIDs.sorted()

        var valueIndex: UInt64 = 0
        func nextValue(scale: Double) -> Double {
            defer { valueIndex &+= 1 }
            return Self.initialValue(seed: configuration.initializationSeed, index: valueIndex, scale: scale)
        }

        tokenEmbeddings = vocabulary.tokens.map { _ in
            (0..<configuration.embeddingDimension).map { _ in nextValue(scale: 0.08) }
        }
        projectionWeights = (0..<configuration.hiddenDimension).map { _ in
            (0..<configuration.embeddingDimension).map { _ in nextValue(scale: 0.08) }
        }
        // A small positive bias prevents an untrained compact model from
        // placing every ReLU unit below zero on a short personal corpus.
        projectionBiases = Array(repeating: 0.02, count: configuration.hiddenDimension)
        outputWeights = labelIDs.sorted().map { _ in
            (0..<configuration.hiddenDimension).map { _ in nextValue(scale: 0.08) }
        }
        outputBiases = Array(repeating: 0, count: labelIDs.count)
    }

    public init(
        configuration: EmbeddedNeuralModelConfiguration = .init(),
        labelIDs: [String],
        trainingExamples: [EmbeddedNeuralTrainingExample]
    ) throws {
        let vocabulary = LocalEmbeddingVocabulary.build(from: trainingExamples, limit: configuration.vocabularyLimit)
        try self.init(configuration: configuration, labelIDs: labelIDs, vocabulary: vocabulary)
    }

    /// A unit-normalized local text vector. The vector can be persisted or used
    /// for local nearest-neighbour tools without running the classifier head.
    public func embedding(for text: String) -> [Double] {
        let hidden = forward(tokenIDs: vocabulary.tokenIDs(for: text)).hidden
        let magnitude = sqrt(hidden.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0, magnitude.isFinite else { return Array(repeating: 0, count: hidden.count) }
        return hidden.map { $0 / magnitude }
    }

    public func predictions(for text: String) -> [EmbeddedNeuralPrediction] {
        let probabilities = forward(tokenIDs: vocabulary.tokenIDs(for: text)).probabilities
        return zip(labelIDs, probabilities).map { EmbeddedNeuralPrediction(labelID: $0.0, probability: $0.1) }
    }

    /// Performs deterministic on-device SGD. Labels not explicitly supplied by
    /// an example are excluded from the loss rather than treated as negatives.
    @discardableResult
    public mutating func train(_ examples: [EmbeddedNeuralTrainingExample], epochs: Int) throws -> EmbeddedNeuralTrainingReport {
        guard epochs > 0 else { throw EmbeddedNeuralModelError.invalidEpochCount }
        let labelPositions = Dictionary(uniqueKeysWithValues: labelIDs.enumerated().map { ($0.element, $0.offset) })
        var totalLoss = 0.0
        var updateCount = 0

        for example in examples {
            try Self.validate(example: example, labelPositions: labelPositions)
        }
        guard examples.contains(where: { !$0.positiveLabelIDs.isEmpty || !$0.negativeLabelIDs.isEmpty }) else {
            throw EmbeddedNeuralModelError.noExplicitLabels
        }

        for _ in 0..<epochs {
            for example in examples {
                let tokenIDs = vocabulary.tokenIDs(for: example.text)
                let forwardPass = forward(tokenIDs: tokenIDs)
                let targets = explicitTargets(for: example, labelPositions: labelPositions)
                let normalization = 1 / Double(targets.count)
                var outputGradient = Array(repeating: 0.0, count: labelIDs.count)
                var hiddenGradient = Array(repeating: 0.0, count: configuration.hiddenDimension)

                for (labelIndex, target) in targets {
                    let probability = forwardPass.probabilities[labelIndex]
                    let bounded = min(1 - 1e-12, max(1e-12, probability))
                    totalLoss -= target * log(bounded) + (1 - target) * log(1 - bounded)
                    let gradient = normalization * (probability - target)
                    outputGradient[labelIndex] = gradient
                    for hiddenIndex in 0..<configuration.hiddenDimension {
                        hiddenGradient[hiddenIndex] += outputWeights[labelIndex][hiddenIndex] * gradient
                    }
                    updateCount += 1
                }

                var projectionGradient = Array(
                    repeating: Array(repeating: 0.0, count: configuration.embeddingDimension),
                    count: configuration.hiddenDimension
                )
                var projectionBiasGradient = Array(repeating: 0.0, count: configuration.hiddenDimension)
                var pooledGradient = Array(repeating: 0.0, count: configuration.embeddingDimension)
                for hiddenIndex in 0..<configuration.hiddenDimension {
                    let gradient = forwardPass.preActivation[hiddenIndex] > 0 ? hiddenGradient[hiddenIndex] : 0
                    projectionBiasGradient[hiddenIndex] = gradient
                    for embeddingIndex in 0..<configuration.embeddingDimension {
                        projectionGradient[hiddenIndex][embeddingIndex] = gradient * forwardPass.pooled[embeddingIndex]
                        pooledGradient[embeddingIndex] += projectionWeights[hiddenIndex][embeddingIndex] * gradient
                    }
                }

                applyOutputGradient(outputGradient, hidden: forwardPass.hidden)
                applyProjectionGradient(projectionGradient, biasGradient: projectionBiasGradient)
                let tokenScale = 1 / Double(tokenIDs.count)
                for tokenID in tokenIDs {
                    for embeddingIndex in 0..<configuration.embeddingDimension {
                        tokenEmbeddings[tokenID][embeddingIndex] -= configuration.learningRate * (pooledGradient[embeddingIndex] * tokenScale + configuration.l2Penalty * tokenEmbeddings[tokenID][embeddingIndex])
                    }
                }
            }
        }

        return .init(
            epochs: epochs,
            exampleCount: examples.count,
            labelUpdateCount: updateCount,
            meanBinaryCrossEntropy: updateCount == 0 ? 0 : totalLoss / Double(updateCount)
        )
    }

    private func forward(tokenIDs: [Int]) -> ForwardPass {
        var pooled = Array(repeating: 0.0, count: configuration.embeddingDimension)
        for tokenID in tokenIDs {
            for embeddingIndex in 0..<configuration.embeddingDimension {
                pooled[embeddingIndex] += tokenEmbeddings[tokenID][embeddingIndex]
            }
        }
        let tokenScale = 1 / Double(tokenIDs.count)
        pooled = pooled.map { $0 * tokenScale }

        var preActivation = Array(repeating: 0.0, count: configuration.hiddenDimension)
        var hidden = Array(repeating: 0.0, count: configuration.hiddenDimension)
        for hiddenIndex in 0..<configuration.hiddenDimension {
            preActivation[hiddenIndex] = projectionBiases[hiddenIndex]
            for embeddingIndex in 0..<configuration.embeddingDimension {
                preActivation[hiddenIndex] += projectionWeights[hiddenIndex][embeddingIndex] * pooled[embeddingIndex]
            }
            hidden[hiddenIndex] = max(0, preActivation[hiddenIndex])
        }

        var probabilities = Array(repeating: 0.0, count: labelIDs.count)
        for labelIndex in labelIDs.indices {
            var logit = outputBiases[labelIndex]
            for hiddenIndex in 0..<configuration.hiddenDimension {
                logit += outputWeights[labelIndex][hiddenIndex] * hidden[hiddenIndex]
            }
            probabilities[labelIndex] = sigmoid(logit)
        }
        return .init(pooled: pooled, preActivation: preActivation, hidden: hidden, probabilities: probabilities)
    }

    private mutating func applyOutputGradient(_ gradient: [Double], hidden: [Double]) {
        for labelIndex in labelIDs.indices where gradient[labelIndex] != 0 {
            for hiddenIndex in 0..<configuration.hiddenDimension {
                outputWeights[labelIndex][hiddenIndex] -= configuration.learningRate * (gradient[labelIndex] * hidden[hiddenIndex] + configuration.l2Penalty * outputWeights[labelIndex][hiddenIndex])
            }
            outputBiases[labelIndex] -= configuration.learningRate * gradient[labelIndex]
        }
    }

    private mutating func applyProjectionGradient(_ gradient: [[Double]], biasGradient: [Double]) {
        for hiddenIndex in 0..<configuration.hiddenDimension {
            for embeddingIndex in 0..<configuration.embeddingDimension {
                projectionWeights[hiddenIndex][embeddingIndex] -= configuration.learningRate * (gradient[hiddenIndex][embeddingIndex] + configuration.l2Penalty * projectionWeights[hiddenIndex][embeddingIndex])
            }
            projectionBiases[hiddenIndex] -= configuration.learningRate * biasGradient[hiddenIndex]
        }
    }

    private func explicitTargets(
        for example: EmbeddedNeuralTrainingExample,
        labelPositions: [String: Int]
    ) -> [(Int, Double)] {
        let positives = example.positiveLabelIDs.compactMap { labelPositions[$0].map { ($0, 1.0) } }
        let negatives = example.negativeLabelIDs.compactMap { labelPositions[$0].map { ($0, 0.0) } }
        return positives + negatives
    }

    private static func validate(configuration: EmbeddedNeuralModelConfiguration, labelIDs: [String]) throws {
        guard configuration.vocabularyLimit >= 2,
              configuration.embeddingDimension >= 2,
              configuration.hiddenDimension >= 2,
              configuration.learningRate.isFinite,
              configuration.learningRate > 0,
              configuration.l2Penalty.isFinite,
              configuration.l2Penalty >= 0 else {
            throw EmbeddedNeuralModelError.invalidConfiguration
        }
        guard !labelIDs.isEmpty else { throw EmbeddedNeuralModelError.emptyLabelSet }
        var seen = Set<String>()
        for labelID in labelIDs {
            guard !labelID.isEmpty else { throw EmbeddedNeuralModelError.emptyLabelSet }
            guard seen.insert(labelID).inserted else { throw EmbeddedNeuralModelError.duplicateLabelID(labelID) }
        }
    }

    private static func validate(example: EmbeddedNeuralTrainingExample, labelPositions: [String: Int]) throws {
        let positives = Set(example.positiveLabelIDs)
        let negatives = Set(example.negativeLabelIDs)
        for labelID in positives.union(negatives) where labelPositions[labelID] == nil {
            throw EmbeddedNeuralModelError.unknownLabelID(labelID)
        }
        if let overlap = positives.intersection(negatives).sorted().first {
            throw EmbeddedNeuralModelError.overlappingLabels(overlap)
        }
    }

    private static func initialValue(seed: UInt64, index: UInt64, scale: Double) -> Double {
        var value = seed &+ index &* 0x9E37_79B9_7F4A_7C15
        value ^= value >> 30
        value &*= 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value &*= 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        let unit = Double(value & 0xFFFF_FFFF) / Double(UInt32.max)
        return (unit * 2 - 1) * scale
    }

    private struct ForwardPass {
        var pooled: [Double]
        var preActivation: [Double]
        var hidden: [Double]
        var probabilities: [Double]
    }
}
