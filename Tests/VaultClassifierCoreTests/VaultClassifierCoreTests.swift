import CryptoKit
import Foundation
import XCTest
@testable import VaultClassifierCore

final class VaultClassifierCoreTests: XCTestCase {
    private func seed() throws -> VerifiedSeedPackage { try SeedPackageLoader.bundled() }

    private func signedCandidate(
        releaseSequence: Int64,
        releaseVersion: PackageReleaseVersion,
        modelVersion: String,
        privateKey: Curve25519.Signing.PrivateKey,
        publishedAtMilliseconds: Int64 = 1_700_000_000_000
    ) throws -> ModelPackageCandidate {
        var package = try seed().package
        package.modelVersion = modelVersion
        let payload = try JSONEncoder().encode(package)
        let manifest = ModelPackageManifest(
            packageID: package.packageID,
            releaseSequence: releaseSequence,
            releaseVersion: releaseVersion,
            taxonomyVersion: package.taxonomyVersion,
            modelVersion: package.modelVersion,
            payloadSHA256: PackageDigest.sha256Hex(payload),
            payloadByteCount: payload.count,
            publishedAtMilliseconds: publishedAtMilliseconds,
            signingKeyID: "test-key"
        )
        let signature = try privateKey.signature(for: PackageManifestCodec.canonicalData(for: manifest))
        return .init(signedManifest: .init(manifest: manifest, signature: signature), payload: payload)
    }

    private func entry(title: String, sourceID: String? = nil, surface: EntrySurface = .feed) -> EntryEvidence {
        EntryEvidence(platform: "youtube", entryID: UUID().uuidString, sourceID: sourceID, surface: surface, evidence: .init(title: title), policyIDs: [StarterPolicies.clashRoyale.id])
    }

    func testSeedLoadsAndHasOnlyLeafPredictions() throws {
        let package = try seed()
        let taxonomy = try package.taxonomy
        XCTAssertEqual(package.package.modelVersion, "vault-model-1")
        XCTAssertTrue(taxonomy.predictableLeafIDs.contains("content.entities.clash-royale"))
        XCTAssertFalse(taxonomy.predictableLeafIDs.contains("content.entities"))
        XCTAssertEqual(taxonomy.ancestorIDs(for: "content.entities.clash-royale"), ["content.entities", "content"])
    }

    func testEvidenceContractRejectsEmptyOrOversizeEntries() {
        let validator = EntryEvidenceValidator()
        XCTAssertThrowsError(try validator.validate(.init(platform: "youtube", surface: .feed, evidence: .init())))
        XCTAssertThrowsError(try validator.validate(.init(platform: "youtube", surface: .feed, evidence: .init(title: String(repeating: "x", count: 501)))))
        XCTAssertNoThrow(try validator.validate(entry(title: "A compact title")))
    }

    func testFixturesDescribeObservedCapabilitiesAndClassify() throws {
        let fixtures = try YouTubeFixtureCorpus.bundled()
        XCTAssertEqual(fixtures.count, 6)
        var engine = try LocalClassifierEngine(verifiedPackage: seed(), policies: [StarterPolicies.clashRoyale])
        for fixture in fixtures {
            XCTAssertNoThrow(try YouTubeFixtureCorpus.validate(fixture), fixture.id)
            let result = try engine.classify(fixture.entry)
            for expectedTag in fixture.expectedTags {
                XCTAssertTrue(result.selectedLeafTagIDs.contains(expectedTag), "\(fixture.id) should classify \(expectedTag): \(result.scores)")
            }
            XCTAssertEqual(result.strongestAction, fixture.expectedAction, fixture.id)
        }
    }

    func testPoliciesDimFeedButBlockPagesAndExposeAncestors() throws {
        var engine = try LocalClassifierEngine(verifiedPackage: seed(), policies: [StarterPolicies.clashRoyale])
        let feed = try engine.classify(entry(title: "Clash Royale deck gameplay", surface: .feed))
        XCTAssertEqual(feed.strongestAction, .dim)
        XCTAssertTrue(feed.ancestorTagIDs.contains("content.entities"))
        let page = try engine.classify(entry(title: "Clash Royale deck gameplay", surface: .page))
        XCTAssertEqual(page.strongestAction, .block)
    }

    func testSourcePriorRampsToThirtyPercentAndDoesNotUseTargetItself() throws {
        let package = try seed()
        let pristineEntry = entry(title: "Clash Royale ranked match", sourceID: "youtube:source:one")
        var noPrior = try LocalClassifierEngine(verifiedPackage: package, policies: [StarterPolicies.clashRoyale])
        let noPriorResult = try noPrior.classify(pristineEntry)
        let noPriorScore = try XCTUnwrap(noPriorResult.scores.first(where: { $0.tagID == "content.entities.clash-royale" }))

        var firstPass = try LocalClassifierEngine(verifiedPackage: package, policies: [StarterPolicies.clashRoyale])
        let firstPassResult = try firstPass.classify(pristineEntry)
        let firstPassScore = try XCTUnwrap(firstPassResult.scores.first(where: { $0.tagID == "content.entities.clash-royale" }))
        XCTAssertEqual(noPriorScore.finalScore, firstPassScore.finalScore, accuracy: 0.000_001, "A target may not create its own source prior.")

        let profile = SourceProfile(observations: [
            .init(sequence: 1, leafScores: ["content.entities.clash-royale": 1]),
            .init(sequence: 1, leafScores: ["content.entities.clash-royale": 1]),
        ])
        var withPrior = try LocalClassifierEngine(verifiedPackage: package, policies: [StarterPolicies.clashRoyale], sourceProfiles: ["youtube:source:one": profile])
        let priorResult = try withPrior.classify(pristineEntry)
        let priorScore = try XCTUnwrap(priorResult.scores.first(where: { $0.tagID == "content.entities.clash-royale" }))
        XCTAssertEqual(try XCTUnwrap(priorScore.sourceScore), 1, accuracy: 0.000_001)
        XCTAssertEqual(priorScore.finalScore, priorScore.directScore * 0.7 + 0.3, accuracy: 0.000_001)
        let gameplayScore = try XCTUnwrap(priorResult.scores.first(where: { $0.tagID == "content.formats.gameplay" }))
        XCTAssertNil(gameplayScore.sourceScore, "Creator priors must not apply to a format leaf.")
    }

    func testLocalFTRLCorrectionOnlyMovesAnExplicitTag() throws {
        let package = try seed()
        let sample = entry(title: "unusual maker project")
        var engine = try LocalClassifierEngine(verifiedPackage: package)
        let before = try engine.classify(sample).scores.first(where: { $0.tagID == "content.topics.technology" })!.finalScore
        for _ in 0..<12 {
            try engine.trainLocalCorrection(for: "content.topics.technology", isPositive: true, evidence: sample)
        }
        let after = try engine.classify(sample).scores.first(where: { $0.tagID == "content.topics.technology" })!.finalScore
        XCTAssertGreaterThan(after, before)
    }

    func testCacheIsUniqueFIFOAndLedgerRecordsCorrections() throws {
        var state = LocalClassifierState(settings: .init(cacheCapacity: 2))
        var engine = try LocalClassifierEngine(verifiedPackage: seed(), policies: [StarterPolicies.clashRoyale])
        let first = entry(title: "Clash Royale guide")
        let second = entry(title: "Minecraft gameplay")
        let third = entry(title: "Programming tutorial")
        for item in [first, second, third] { state.record(entry: item, result: try engine.classify(item)) }
        XCTAssertEqual(state.cache.count, 2)
        XCTAssertFalse(state.cache.contains(where: { $0.key == LocalClassifierState.cacheKey(for: first) }))
        let latest = try XCTUnwrap(state.ledger.last)
        state.setCorrection(ledgerID: latest.id, correction: .falseAllow)
        XCTAssertEqual(state.ledger.last?.correction, .falseAllow)
        state.record(entry: third, result: try engine.classify(third))
        XCTAssertEqual(state.cache.count, 2, "Recording the same item replaces its cache row rather than consuming capacity.")
    }

    func testLegacyResourceSettingsDecodeWithAutomaticPackageUpdates() throws {
        let legacyData = Data("""
        {
          "resourceProfile": "light",
          "cacheCapacity": 12000,
          "allowIdleWork": false,
          "allowBackgroundSync": true,
          "allowLocalLLMAudit": true
        }
        """.utf8)
        let settings = try JSONDecoder().decode(ClassifierSettings.self, from: legacyData)
        XCTAssertEqual(settings.resourceProfile, .light)
        XCTAssertEqual(settings.cacheCapacity, 12_000)
        XCTAssertFalse(settings.allowIdleWork)
        XCTAssertEqual(settings.packageUpdateMode, .automatic)
    }

    func testRetiredAuditStateAndLabelsAreDiscardedOnLoad() throws {
        let evidence = entry(title: "A saved local label")
        let trainingExample = LocalTrainingExample(
            cacheKey: LocalClassifierState.cacheKey(for: evidence),
            evidence: evidence,
            positiveLeafTagIDs: ["content.entities.clash-royale"],
            origin: .explicitUser,
            taxonomyVersion: "vault-taxonomy-1",
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
        let state = LocalClassifierState(trainingCorpus: .init(examples: [trainingExample]))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        payload["auditState"] = ["retired": true]
        var corpus = try XCTUnwrap(payload["trainingCorpus"] as? [String: Any])
        var examples = try XCTUnwrap(corpus["examples"] as? [[String: Any]])
        examples[0]["origin"] = "confirmedPersonalAudit"
        corpus["examples"] = examples
        payload["trainingCorpus"] = corpus

        let retiredPayload = try JSONSerialization.data(withJSONObject: payload)
        let migrated = try JSONDecoder().decode(LocalClassifierState.self, from: retiredPayload)
        XCTAssertTrue(migrated.trainingCorpus.examples.isEmpty)
        XCTAssertNil(migrated.trainingCorpus.lastRun)

        let saved = String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self)
        XCTAssertFalse(saved.contains("auditState"))
        XCTAssertFalse(saved.contains("confirmedPersonalAudit"))
        XCTAssertFalse(saved.contains("allowLocalLLMAudit"))
    }

    func testLocalStateRoundTripsAndSeedBackupRetainsRecentPackages() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LocalStateFile(url: root.appendingPathComponent("state.json"))
        let state = LocalClassifierState(settings: .init(resourceProfile: .light))
        try file.save(state)
        XCTAssertEqual(try file.load(), state)

        let backup = LocalSeedBackup()
        let destination = try backup.backup(seed(), in: root.appendingPathComponent("backups", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("seed-package.json").path))
        let manifest = try JSONDecoder().decode(SeedBackupManifest.self, from: Data(contentsOf: destination.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.packageID, "vault-seed-2026-07-15")
    }

    func testCoordinatorPersistsTheClassificationAndCorrectionLedger() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateFile = LocalStateFile(url: root.appendingPathComponent("state.json"))
        let coordinator = try LocalClassifierCoordinator(verifiedPackage: seed(), stateFile: stateFile, defaultPolicies: [StarterPolicies.clashRoyale])
        _ = try coordinator.classify(entry(title: "Clash Royale gameplay"))
        let ledger = try XCTUnwrap(coordinator.snapshot().ledger.last)
        try coordinator.setCorrection(ledgerID: ledger.id, correction: .falseDim)
        let reloaded = try LocalStateFile(url: stateFile.url).load()
        XCTAssertEqual(reloaded.cache.count, 1)
        XCTAssertEqual(reloaded.ledger.last?.correction, .falseDim)
    }

    func testEphemeralEd25519SignatureContractRejectsTampering() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = Data("seed data".utf8)
        let signature = try privateKey.signature(for: payload)
        let verifier = Ed25519SignatureVerifier(publicKey: privateKey.publicKey.rawRepresentation)
        XCTAssertTrue(verifier.verify(.init(payload: payload, signature: signature)))
        XCTAssertFalse(verifier.verify(.init(payload: Data("tampered".utf8), signature: signature)))
    }

    func testSharedBrowserBridgeFramesAreStrictlyBounded() {
        XCTAssertEqual(SharedBrowserBridgeProtocol.version, 4)
        XCTAssertEqual(SharedBrowserBridgeProtocol.address, "ws://127.0.0.1:8787")
        XCTAssertEqual(SharedBrowserBridgeOperation.diagnostic.rawValue, "diagnostic")
        XCTAssertTrue(SharedBrowserBridgeProtocol.isValidRequestID("request-001"))
        XCTAssertFalse(SharedBrowserBridgeProtocol.isValidRequestID("request\n001"))
        XCTAssertTrue(SharedBrowserBridgeProtocol.isValidBody(["entry": ["title": "Visible card"]]))
        XCTAssertFalse(SharedBrowserBridgeProtocol.isValidBody(["entry": String(repeating: "x", count: SharedBrowserBridgeProtocol.maximumBodyBytes + 1)]))
        XCTAssertTrue(SharedBrowserBridgeProtocol.isAcceptedHubProgram("macapp"))
        XCTAssertTrue(SharedBrowserBridgeProtocol.isAcceptedHubProgram("classifier"))
        XCTAssertFalse(SharedBrowserBridgeProtocol.isAcceptedHubProgram("vault-broker"))
        XCTAssertFalse(SharedBrowserBridgeProtocol.isAcceptedHubProgram("browser"))
    }

    func testLocalHubProofBindsTheProgramAndChallenge() throws {
        let secret = Data(repeating: 7, count: 32)
        let challenge = String(repeating: "a", count: 43)
        let proof = try LocalHubAuthentication.makeProof(
            program: "chrome",
            challenge: challenge,
            secret: secret
        )

        XCTAssertEqual(proof, "KdU7-EvPwn1g60PF6bYZsqVfl-AD19TbQmtaLmHbyQc")
        XCTAssertTrue(LocalHubAuthentication.verifyProof(
            program: "chrome",
            challenge: challenge,
            proof: proof,
            secret: secret
        ))
        XCTAssertFalse(LocalHubAuthentication.verifyProof(
            program: "edge",
            challenge: challenge,
            proof: proof,
            secret: secret
        ))
        XCTAssertFalse(LocalHubAuthentication.verifyProof(
            program: "chrome",
            challenge: String(repeating: "b", count: 43),
            proof: proof,
            secret: secret
        ))
    }

    func testCollectionDiagnosticsUseOnlySafePlatformIdentifiers() throws {
        let diagnostic = NativeCollectionDiagnosticRequest(
            platformID: "youtube",
            event: .pageEvidenceMissing,
            detail: .missingCreator
        )
        XCTAssertNoThrow(try diagnostic.validate())
        XCTAssertThrowsError(try NativeCollectionDiagnosticRequest(
            platformID: "youtube raw title",
            event: .collectionRequested
        ).validate()) { error in
            guard case NativeCollectionDiagnosticError.invalidPlatform = error else {
                return XCTFail("Expected invalid platform diagnostic error")
            }
        }
    }

    func testCollectedEntriesDeduplicateWithoutChangingDatasetRevision() {
        var dataset = ClassificationDataset(id: "dataset", name: "Local data")
        let originalRevision = dataset.revision
        let initial = CollectedPlatformEntry(
            id: "collected-video",
            platformID: "youtube",
            entryID: "youtube:video:one",
            creatorID: "youtube:channel:one",
            creatorName: "Creator one",
            entryType: "video",
            title: "First visible title",
            attributes: ["subscriberCount": "12K"],
            firstObservedAtMilliseconds: 100,
            lastObservedAtMilliseconds: 100
        )
        XCTAssertTrue(dataset.upsertCollectedEntry(initial))
        var refreshed = initial
        refreshed.title = "Updated visible title"
        refreshed.lastObservedAtMilliseconds = 200
        XCTAssertFalse(dataset.upsertCollectedEntry(refreshed))
        XCTAssertEqual(dataset.revision, originalRevision)
        XCTAssertEqual(dataset.collectedEntries.count, 1)
        XCTAssertEqual(dataset.collectedEntries[0].title, "Updated visible title")
        XCTAssertEqual(dataset.collectedEntries[0].firstObservedAtMilliseconds, 100)
        XCTAssertEqual(dataset.collectedEntries[0].observationCount, 2)
    }

    func testCollectionDefaultsOnForKnownBindingsAndKeepsLabelsSeparate() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateFile = LocalStateFile(url: root.appendingPathComponent("state.json"))
        let coordinator = try LocalClassifierCoordinator(verifiedPackage: seed(), stateFile: stateFile)
        let collected = EntryEvidence(
            platform: "youtube",
            entryID: "youtube:video:collection-test",
            sourceID: "youtube:channel:collection-test",
            surface: .feed,
            evidence: .init(title: "Visible platform entry", metadata: [
                "sourceName": .string("Creator test"),
                "entryType": .string("video"),
                "subscriberCount": .string("4K"),
                "published": .string("2 days ago"),
                "creatorAvatarURL": .string("https://yt3.ggpht.com/creator-avatar=s88"),
            ])
        )
        XCTAssertEqual(coordinator.enabledCollectionPlatformIDs(), ["youtube"])
        XCTAssertTrue(try coordinator.collectPlatformEntry(collected, at: 123))

        let dataset = try XCTUnwrap(coordinator.snapshot().workspaceCatalog.datasets.first)
        XCTAssertEqual(dataset.records.count, 0)
        XCTAssertEqual(dataset.collectedEntries.count, 1)
        XCTAssertEqual(dataset.collectedEntries[0].creatorName, "Creator test")
        XCTAssertEqual(dataset.collectedEntries[0].attributes["subscriberCount"], "4K")
        XCTAssertEqual(dataset.collectedEntries[0].attributes["published"], "2 days ago")
        XCTAssertEqual(dataset.collectedEntries[0].attributes["creatorAvatarURL"], "https://yt3.ggpht.com/creator-avatar=s88")
    }

    func testCollectionDropsUntrustedCreatorAvatarURLsWithoutDroppingTheEntry() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try LocalClassifierCoordinator(verifiedPackage: seed(), stateFile: LocalStateFile(url: root.appendingPathComponent("state.json")))
        let collected = EntryEvidence(
            platform: "youtube",
            entryID: "youtube:video:untrusted-avatar",
            sourceID: "youtube:channel:untrusted-avatar",
            surface: .feed,
            evidence: .init(title: "Visible platform entry", metadata: [
                "sourceName": .string("Creator test"),
                "entryType": .string("video"),
                "creatorAvatarURL": .string("https://images.example.invalid/not-an-author.png"),
            ])
        )
        XCTAssertTrue(try coordinator.collectPlatformEntry(collected, at: 123))
        let dataset = try XCTUnwrap(coordinator.snapshot().workspaceCatalog.datasets.first)
        XCTAssertNil(dataset.collectedEntries[0].attributes["creatorAvatarURL"])
        XCTAssertFalse(CreatorAvatarURLPolicy.isAccepted(platformID: "youtube", value: "https://images.example.invalid/not-an-author.png"))
    }

    func testSignedModelPackageManifestBindsChecksumSignatureAndPayloadMetadata() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let candidate = try signedCandidate(
            releaseSequence: 1,
            releaseVersion: try .init(major: 1, minor: 0, patch: 0),
            modelVersion: "vault-model-1",
            privateKey: privateKey
        )
        let keyring = try PackageSigningKeyring([.init(keyID: "test-key", publicKey: privateKey.publicKey.rawRepresentation)])
        let verified = try PackageManifestValidator(keyring: keyring).verify(candidate)
        XCTAssertEqual(verified.manifest.releaseSequence, 1)
        XCTAssertEqual(verified.seedPackage.package.modelVersion, "vault-model-1")

        var tampered = candidate
        tampered.payload[tampered.payload.startIndex] ^= 0x01
        XCTAssertThrowsError(try PackageManifestValidator(keyring: keyring).verify(tampered)) { error in
            guard case .checksumMismatch = error as? PackageManifestValidationError else {
                return XCTFail("Expected a SHA-256 integrity error, got \(error)")
            }
        }

        var mismatchedManifest = candidate.signedManifest.manifest
        mismatchedManifest.modelVersion = "vault-model-incorrect"
        let mismatchSignature = try privateKey.signature(for: PackageManifestCodec.canonicalData(for: mismatchedManifest))
        let mismatched = ModelPackageCandidate(
            signedManifest: .init(manifest: mismatchedManifest, signature: mismatchSignature),
            payload: candidate.payload
        )
        XCTAssertThrowsError(try PackageManifestValidator(keyring: keyring).verify(mismatched)) { error in
            XCTAssertEqual(error as? PackageManifestValidationError, .payloadMetadataMismatch("modelVersion"))
        }
    }

    func testLifecycleStagesActivatesRollsBackAndRetainsMonotonicHighWaterMark() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let keyring = try PackageSigningKeyring([.init(keyID: "test-key", publicKey: privateKey.publicKey.rawRepresentation)])
        let lifecycle = LocalPackageLifecycle(rootDirectory: root, keyring: keyring)
        let first = try signedCandidate(
            releaseSequence: 1,
            releaseVersion: try .init(major: 1, minor: 0, patch: 0),
            modelVersion: "vault-model-1",
            privateKey: privateKey
        )
        let firstReference = try lifecycle.stage(first, at: Date(timeIntervalSince1970: 1))
        XCTAssertNil(try lifecycle.snapshot().active)
        XCTAssertEqual(try lifecycle.activateStaged(at: Date(timeIntervalSince1970: 3)).id, firstReference.id)
        XCTAssertEqual(try lifecycle.activePackage()?.manifest.releaseSequence, 1)
        let statePermissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("lifecycle.json").path)[.posixPermissions] as? NSNumber
        let packageDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("packages"), includingPropertiesForKeys: nil).first
        )
        let packagePermissions = try FileManager.default.attributesOfItem(atPath: packageDirectory.appendingPathComponent("seed-package.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(try XCTUnwrap(statePermissions).intValue & 0o777, 0o600)
        XCTAssertEqual(try XCTUnwrap(packagePermissions).intValue & 0o777, 0o600)

        let second = try signedCandidate(
            releaseSequence: 2,
            releaseVersion: try .init(major: 1, minor: 1, patch: 0),
            modelVersion: "vault-model-2",
            privateKey: privateKey,
            publishedAtMilliseconds: 1_700_000_000_001
        )
        let secondReference = try lifecycle.stage(second, at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(try lifecycle.activateStaged(at: Date(timeIntervalSince1970: 4)).id, secondReference.id)
        XCTAssertEqual(try lifecycle.snapshot().rollbackPackages.map(\.id), [firstReference.id])

        XCTAssertEqual(try lifecycle.rollback().id, firstReference.id)
        XCTAssertEqual(try lifecycle.activePackage()?.manifest.releaseSequence, 1)
        XCTAssertEqual(try lifecycle.snapshot().highestAcceptedRelease?.releaseSequence, 2)
        XCTAssertThrowsError(try lifecycle.stage(first)) { error in
            guard case .nonMonotonicUpdate = error as? PackageManifestValidationError else {
                return XCTFail("Expected high-water rejection, got \(error)")
            }
        }
        let higherSequenceButOlderVersion = try signedCandidate(
            releaseSequence: 3,
            releaseVersion: try .init(major: 1, minor: 0, patch: 1),
            modelVersion: "vault-model-3",
            privateKey: privateKey,
            publishedAtMilliseconds: 1_700_000_000_002
        )
        XCTAssertThrowsError(try lifecycle.stage(higherSequenceButOlderVersion)) { error in
            guard case .nonMonotonicUpdate = error as? PackageManifestValidationError else {
                return XCTFail("Expected semantic-version safety rejection, got \(error)")
            }
        }

        // A downloaded-but-declined package never changes the active high-water mark.
        let pending = try signedCandidate(
            releaseSequence: 3,
            releaseVersion: try .init(major: 1, minor: 2, patch: 0),
            modelVersion: "vault-model-3",
            privateKey: privateKey,
            publishedAtMilliseconds: 1_700_000_000_003
        )
        let pendingReference = try lifecycle.stage(pending)
        try lifecycle.discardStaged()
        XCTAssertEqual(try lifecycle.stage(pending).id, pendingReference.id)
    }

    func testLifecyclePrunesOnlyUnreferencedPrivatePackageDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let privateKey = Curve25519.Signing.PrivateKey()
        let keyring = try PackageSigningKeyring([.init(keyID: "test-key", publicKey: privateKey.publicKey.rawRepresentation)])
        let lifecycle = LocalPackageLifecycle(rootDirectory: root, keyring: keyring)

        var references: [LocalPackageReference] = []
        for release in 1...5 {
            let candidate = try signedCandidate(
                releaseSequence: Int64(release),
                releaseVersion: try .init(major: 1, minor: 0, patch: release),
                modelVersion: "vault-model-\(release)",
                privateKey: privateKey,
                publishedAtMilliseconds: 1_700_000_000_000 + Int64(release)
            )
            references.append(try lifecycle.stage(candidate))
            _ = try lifecycle.activateStaged()
        }

        let packages = root.appendingPathComponent("packages", isDirectory: true)
        func storageName(_ reference: LocalPackageReference) -> String {
            "release-\(reference.manifest.releaseSequence)-\(reference.manifest.payloadSHA256)"
        }
        XCTAssertFalse(fileManager.fileExists(atPath: packages.appendingPathComponent(storageName(references[0])).path))

        // A stale complete directory is safe to remove during rollback.
        let orphanName = "release-999-\(String(repeating: "a", count: 64))"
        try fileManager.copyItem(
            at: packages.appendingPathComponent(storageName(references[1]), isDirectory: true),
            to: packages.appendingPathComponent(orphanName, isDirectory: true)
        )
        _ = try lifecycle.rollback()
        XCTAssertFalse(fileManager.fileExists(atPath: packages.appendingPathComponent(orphanName).path))

        // A staged package is removed when declined, but a similarly named
        // symlink is neither followed nor removed by cleanup.
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try Data("outside package store".utf8).write(to: sentinel)
        let symlinkName = "release-998-\(String(repeating: "b", count: 64))"
        let symlink = packages.appendingPathComponent(symlinkName)
        try fileManager.createSymbolicLink(atPath: symlink.path, withDestinationPath: outside.path)

        let pending = try signedCandidate(
            releaseSequence: 6,
            releaseVersion: try .init(major: 1, minor: 0, patch: 6),
            modelVersion: "vault-model-6",
            privateKey: privateKey,
            publishedAtMilliseconds: 1_700_000_000_006
        )
        let pendingReference = try lifecycle.stage(pending)
        try lifecycle.discardStaged()

        let state = try lifecycle.snapshot()
        XCTAssertNil(state.staged)
        XCTAssertEqual(state.active?.id, references[3].id)
        XCTAssertEqual(state.rollbackPackages.map(\.id), [references[4].id, references[2].id, references[1].id])
        XCTAssertFalse(fileManager.fileExists(atPath: packages.appendingPathComponent(storageName(pendingReference)).path))
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: symlink.path), outside.path)
        XCTAssertTrue(fileManager.fileExists(atPath: sentinel.path))

        let packageNames = try fileManager.contentsOfDirectory(atPath: packages.path)
        let retainedNames = Set([references[1], references[2], references[3], references[4]].map(storageName))
        XCTAssertTrue(retainedNames.isSubset(of: Set(packageNames)))
    }

    func testDailyPackageSyncPlannerRespectsModeBackgroundSettingAndTwentyFourHourCadence() throws {
        let planner = DailyPackageSyncPlanner()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var state = LocalPackageLifecycleState()
        XCTAssertEqual(
            planner.decision(now: start, state: state, updateMode: .automatic, backgroundSyncEnabled: true),
            .checkManifest(downloadDisposition: .automatic)
        )
        state.lastManifestCheckAt = start
        XCTAssertEqual(
            planner.decision(now: start.addingTimeInterval(23 * 60 * 60), state: state, updateMode: .downloadThenAsk, backgroundSyncEnabled: true),
            .waitUntil(start.addingTimeInterval(DailyPackageSyncPlanner.interval))
        )
        XCTAssertEqual(
            planner.decision(now: start.addingTimeInterval(DailyPackageSyncPlanner.interval), state: state, updateMode: .downloadThenAsk, backgroundSyncEnabled: true),
            .checkManifest(downloadDisposition: .askBeforeDownload)
        )
        XCTAssertEqual(
            planner.decision(now: start, state: state, updateMode: .automatic, backgroundSyncEnabled: false),
            .backgroundSyncDisabled
        )
        XCTAssertEqual(
            planner.decision(now: start, state: state, updateMode: .manual, backgroundSyncEnabled: true),
            .manualOnly
        )
    }
}
