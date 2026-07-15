import Foundation

public struct EvidenceAvailability: Codable, Equatable, Sendable {
    public var entryID: Bool
    public var sourceID: Bool
    public var title: Bool
    public var description: Bool
    public var suppliedTags: Bool
    public var aiSummary: Bool

    public init(entryID: Bool, sourceID: Bool, title: Bool, description: Bool, suppliedTags: Bool, aiSummary: Bool) {
        self.entryID = entryID
        self.sourceID = sourceID
        self.title = title
        self.description = description
        self.suppliedTags = suppliedTags
        self.aiSummary = aiSummary
    }
}

public struct YouTubeEvidenceFixture: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var purpose: String
    public var availability: EvidenceAvailability
    public var entry: EntryEvidence
    public var expectedTags: [String]
    public var expectedAction: PresentationAction

    public init(id: String, purpose: String, availability: EvidenceAvailability, entry: EntryEvidence, expectedTags: [String], expectedAction: PresentationAction) {
        self.id = id
        self.purpose = purpose
        self.availability = availability
        self.entry = entry
        self.expectedTags = expectedTags
        self.expectedAction = expectedAction
    }
}

public enum FixtureContractError: Error, Equatable, LocalizedError, Sendable {
    case missingExpectedCapability(String, String)
    case unexpectedCapability(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingExpectedCapability(let fixture, let field): return "Fixture \(fixture) is missing expected \(field)."
        case .unexpectedCapability(let fixture, let field): return "Fixture \(fixture) unexpectedly has \(field)."
        }
    }
}

public enum YouTubeFixtureCorpus {
    public static func bundled() throws -> [YouTubeEvidenceFixture] {
        guard let url = Bundle.module.url(forResource: "youtube-fixtures", withExtension: "json", subdirectory: "Resources") else {
            throw SeedPackageError.missingResource("youtube-fixtures")
        }
        return try JSONDecoder().decode([YouTubeEvidenceFixture].self, from: Data(contentsOf: url))
    }

    public static func validate(_ fixture: YouTubeEvidenceFixture) throws {
        let checks: [(String, Bool, Bool)] = [
            ("entryID", fixture.availability.entryID, fixture.entry.entryID != nil),
            ("sourceID", fixture.availability.sourceID, fixture.entry.sourceID != nil),
            ("title", fixture.availability.title, fixture.entry.evidence.title != nil),
            ("description", fixture.availability.description, fixture.entry.evidence.text != nil),
            ("suppliedTags", fixture.availability.suppliedTags, !fixture.entry.evidence.suppliedTags.isEmpty),
            ("aiSummary", fixture.availability.aiSummary, fixture.entry.evidence.summary != nil),
        ]
        for (field, expected, actual) in checks {
            if expected && !actual { throw FixtureContractError.missingExpectedCapability(fixture.id, field) }
            if !expected && actual { throw FixtureContractError.unexpectedCapability(fixture.id, field) }
        }
    }
}

public enum StarterPolicies {
    public static let clashRoyale = NamedPolicy(
        id: "clash-royale-focus",
        name: "Clash Royale focus",
        includeAnyTagIDs: ["content.entities.clash-royale"],
        feedAction: .dim,
        pageAction: .block
    )
}
