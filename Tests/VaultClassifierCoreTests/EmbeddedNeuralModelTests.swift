import XCTest
@testable import VaultClassifierCore

final class EmbeddedNeuralModelTests: XCTestCase {
    private let examples = [
        EmbeddedNeuralTrainingExample(text: "cat purr whiskers", positiveLabelIDs: ["cat"], negativeLabelIDs: ["dog"]),
        EmbeddedNeuralTrainingExample(text: "cat meow kitten", positiveLabelIDs: ["cat"], negativeLabelIDs: ["dog"]),
        EmbeddedNeuralTrainingExample(text: "dog bark fetch", positiveLabelIDs: ["dog"], negativeLabelIDs: ["cat"]),
        EmbeddedNeuralTrainingExample(text: "dog puppy leash", positiveLabelIDs: ["dog"], negativeLabelIDs: ["cat"]),
    ]

    private var configuration: EmbeddedNeuralModelConfiguration {
        .init(vocabularyLimit: 64, embeddingDimension: 12, hiddenDimension: 10, learningRate: 0.16, l2Penalty: 0.0001, initializationSeed: 42)
    }

    func testVocabularyBuildsDeterministicallyAndFallsBackToUnknownToken() {
        let vocabulary = LocalEmbeddingVocabulary.build(from: examples, limit: 8)
        XCTAssertEqual(vocabulary.tokens.first, LocalEmbeddingVocabulary.unknownToken)
        XCTAssertEqual(vocabulary.tokens, LocalEmbeddingVocabulary.build(from: examples.reversed(), limit: 8).tokens)
        XCTAssertEqual(vocabulary.tokenIDs(for: "unseenword"), [0])
        XCTAssertFalse(vocabulary.tokenIDs(for: "cat dog").contains(0))
    }

    func testEmbeddingIsDeterministicAndUnitNormalized() throws {
        let first = try EmbeddedNeuralTextClassifier(configuration: configuration, labelIDs: ["dog", "cat"], trainingExamples: examples)
        let second = try EmbeddedNeuralTextClassifier(configuration: configuration, labelIDs: ["cat", "dog"], trainingExamples: examples)
        let firstEmbedding = first.embedding(for: "cat purr")
        XCTAssertEqual(firstEmbedding, second.embedding(for: "cat purr"))
        XCTAssertEqual(firstEmbedding.count, configuration.hiddenDimension)
        XCTAssertEqual(firstEmbedding.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 0.000_001)
    }

    func testTrainingLearnsTextEmbeddingsAndMultiLabelHead() throws {
        var model = try EmbeddedNeuralTextClassifier(configuration: configuration, labelIDs: ["cat", "dog"], trainingExamples: examples)
        let report = try model.train(examples, epochs: 1_000)

        XCTAssertEqual(report.exampleCount, examples.count)
        XCTAssertEqual(report.labelUpdateCount, examples.count * 2 * 1_000)
        XCTAssertLessThan(report.meanBinaryCrossEntropy, 0.25)

        let cat = Dictionary(uniqueKeysWithValues: model.predictions(for: "cat meow purr").map { ($0.labelID, $0.probability) })
        let dog = Dictionary(uniqueKeysWithValues: model.predictions(for: "dog bark leash").map { ($0.labelID, $0.probability) })
        XCTAssertGreaterThan(cat["cat"] ?? 0, 0.8)
        XCTAssertLessThan(cat["dog"] ?? 1, 0.2)
        XCTAssertGreaterThan(dog["dog"] ?? 0, 0.8)
        XCTAssertLessThan(dog["cat"] ?? 1, 0.2)
    }

    func testModelRoundTripsAndRejectsInvalidTrainingLabels() throws {
        var model = try EmbeddedNeuralTextClassifier(configuration: configuration, labelIDs: ["cat", "dog"], trainingExamples: examples)
        _ = try model.train(examples, epochs: 2)
        let restored = try JSONDecoder().decode(EmbeddedNeuralTextClassifier.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored, model)
        XCTAssertEqual(restored.predictions(for: "cat purr"), model.predictions(for: "cat purr"))

        XCTAssertThrowsError(try model.train([
            .init(text: "cat", positiveLabelIDs: ["cat"], negativeLabelIDs: ["cat"])
        ], epochs: 1)) { error in
            XCTAssertEqual(error as? EmbeddedNeuralModelError, .overlappingLabels("cat"))
        }
        XCTAssertThrowsError(try model.train([
            .init(text: "unknown", positiveLabelIDs: ["other"])
        ], epochs: 1)) { error in
            XCTAssertEqual(error as? EmbeddedNeuralModelError, .unknownLabelID("other"))
        }
    }
}
