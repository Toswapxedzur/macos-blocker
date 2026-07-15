import Foundation

public enum NgramFeatures {
    public static func features(for evidence: EvidencePayload, limit: Int = 512) -> [String] {
        var fragments = [evidence.title, evidence.text, evidence.summary].compactMap { $0 }
        fragments.append(contentsOf: evidence.suppliedTags)
        let input = fragments
            .joined(separator: " ")
            .folding(options: String.CompareOptions.caseInsensitive.union(.diacriticInsensitive), locale: Locale.current)
            .lowercased()

        let words = input.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && $0.count <= 64 }
        var result = Set(words.map { "w:\($0)" })
        for pair in zip(words, words.dropFirst()) {
            result.insert("b:\(pair.0)_\(pair.1)")
        }
        for word in words where word.count >= 4 {
            let characters = Array(word)
            for index in 0...(characters.count - 3) {
                result.insert("c:" + String(characters[index..<(index + 3)]))
            }
        }
        return Array(result.sorted().prefix(limit))
    }
}

public struct SparseLinearModel: Codable, Equatable, Sendable {
    public var biases: [String: Double]
    public var weights: [String: [String: Double]]

    public init(biases: [String: Double] = [:], weights: [String: [String: Double]] = [:]) {
        self.biases = biases
        self.weights = weights
    }

    public func logit(for tagID: String, features: [String]) -> Double {
        features.reduce(biases[tagID] ?? 0) { $0 + (weights[tagID]?[$1] ?? 0) }
    }

    public func probability(for tagID: String, features: [String]) -> Double {
        sigmoid(logit(for: tagID, features: features))
    }
}

public struct FTRLSettings: Codable, Equatable, Sendable {
    public var alpha: Double
    public var beta: Double
    public var l1: Double
    public var l2: Double

    public init(alpha: Double = 0.08, beta: Double = 1.0, l1: Double = 0.1, l2: Double = 1.0) {
        self.alpha = alpha
        self.beta = beta
        self.l1 = l1
        self.l2 = l2
    }
}

public struct FTRLFeatureState: Codable, Equatable, Sendable {
    public var z: Double
    public var n: Double

    public init(z: Double = 0, n: Double = 0) { self.z = z; self.n = n }
}

/// A tiny per-installation correction layer. It never calls a provider and is trained only
/// from explicit local corrections; watch and click events are deliberately not labels.
public struct PersonalFTRLModel: Codable, Equatable, Sendable {
    public var settings: FTRLSettings
    public var state: [String: [String: FTRLFeatureState]]

    public init(settings: FTRLSettings = .init(), state: [String: [String: FTRLFeatureState]] = [:]) {
        self.settings = settings
        self.state = state
    }

    public func logitDelta(for tagID: String, features: [String]) -> Double {
        features.reduce(0) { partial, feature in partial + weight(for: state[tagID]?[feature] ?? .init()) }
    }

    public mutating func train(features: [String], tagID: String, isPositive: Bool, baseLogit: Double) {
        let delta = logitDelta(for: tagID, features: features)
        let target = isPositive ? 1.0 : 0.0
        let gradient = sigmoid(baseLogit + delta) - target
        guard gradient.isFinite else { return }
        for feature in features {
            var value = state[tagID]?[feature] ?? .init()
            let oldWeight = weight(for: value)
            let sigma = (sqrt(value.n + gradient * gradient) - sqrt(value.n)) / settings.alpha
            value.z += gradient - sigma * oldWeight
            value.n += gradient * gradient
            state[tagID, default: [:]][feature] = value
        }
    }

    private func weight(for state: FTRLFeatureState) -> Double {
        guard abs(state.z) > settings.l1 else { return 0 }
        let sign = state.z < 0 ? -1.0 : 1.0
        return -(state.z - sign * settings.l1) / ((settings.beta + sqrt(state.n)) / settings.alpha + settings.l2)
    }
}

@inline(__always) public func sigmoid(_ value: Double) -> Double {
    if value >= 0 { return 1 / (1 + exp(-value)) }
    let exponent = exp(value)
    return exponent / (1 + exponent)
}
