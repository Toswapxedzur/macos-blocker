import Foundation

public struct SourceObservation: Codable, Equatable, Sendable {
    public var sequence: Int64
    public var leafScores: [String: Double]

    public init(sequence: Int64, leafScores: [String: Double]) {
        self.sequence = sequence
        self.leafScores = leafScores
    }
}

public struct SourceProfile: Codable, Equatable, Sendable {
    public var observations: [SourceObservation]

    public init(observations: [SourceObservation] = []) { self.observations = observations }

    public func scores(at sequence: Int64, halfLifeEntries: Double) -> (scores: [String: Double], effectiveCount: Double) {
        guard halfLifeEntries > 0 else { return ([:], 0) }
        var weighted: [String: Double] = [:]
        var totalWeight = 0.0
        for observation in observations where observation.sequence <= sequence {
            let distance = Double(sequence - observation.sequence)
            let weight = pow(0.5, distance / halfLifeEntries)
            totalWeight += weight
            for (tagID, score) in observation.leafScores {
                weighted[tagID, default: 0] += score * weight
            }
        }
        guard totalWeight > 0 else { return ([:], 0) }
        return (weighted.mapValues { $0 / totalWeight }, totalWeight)
    }

    public mutating func append(sequence: Int64, leafScores: [String: Double], limit: Int) {
        observations.append(.init(sequence: sequence, leafScores: leafScores))
        if observations.count > limit {
            observations.removeFirst(observations.count - limit)
        }
    }
}

public struct SourcePriorSettings: Codable, Equatable, Sendable {
    public var maximumWeight: Double
    public var minimumEffectiveEntries: Double
    public var halfLifeEntries: Double

    public init(maximumWeight: Double = 0.30, minimumEffectiveEntries: Double = 2, halfLifeEntries: Double = 250) {
        self.maximumWeight = min(max(maximumWeight, 0), 1)
        self.minimumEffectiveEntries = max(minimumEffectiveEntries, 0.001)
        self.halfLifeEntries = max(halfLifeEntries, 1)
    }

    public func effectiveWeight(for effectiveCount: Double) -> Double {
        maximumWeight * min(1, max(0, effectiveCount) / minimumEffectiveEntries)
    }
}
