import Foundation
import VaultClassifierCore
import VaultClassifierResearch
import VaultClassifierLLM

// End-to-end exercise of the full on-device loop against real components:
//   real GGUF engine  →  classify a video  →  grounded research (real Gemini)
//   →  creator/term keyed  →  creator-grounded re-classification.
//
// It runs in an isolated temp state (never touching the app's own state), but
// reuses the Gemini provider the user saved in the app so the key never appears
// here. Only sanitized subjects leave the device, same as the app.

func line(_ s: String = "") { print(s) }
func stage(_ n: Int, _ s: String) { print("\n=== [\(n)] \(s) ===") }
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

// MARK: - Gemini provider from the app's own saved state (key never printed)

func loadGeminiProfile() -> APIKeyProviderProfile? {
    guard let directory = try? VaultRuntimeEnvironment.current.classifierSupportDirectoryURL() else { return nil }
    let stateURL = directory.appendingPathComponent("state.json", isDirectory: false)
    guard let state = try? LocalStateFile(url: stateURL).load() else { return nil }
    return state.workspaceCatalog.providerProfiles.first {
        $0.type == .gemini && !($0.credential ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

guard let geminiProfile = loadGeminiProfile() else {
    fail("error: no saved Gemini provider found in the app state — add one in the app first.")
}
line("• Gemini provider: \"\(geminiProfile.name)\"  (credential loaded from app state, not shown)")

guard let modelPath = VaultLocalLLMEngine.defaultModelPath(preferredFileName: nil) else {
    fail("error: no .gguf model found in the models directory — download one first.")
}
line("• model: \((modelPath as NSString).lastPathComponent)")

// MARK: - Isolated coordinator + seeded scenario

let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("vault-fullloop-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
let stateFile = LocalStateFile(url: tempRoot.appendingPathComponent("state.json"))
let coordinator: LocalClassifierCoordinator
do {
    coordinator = try LocalClassifierCoordinator(verifiedPackage: SeedPackageLoader.bundled(), stateFile: stateFile)
} catch {
    fail("error: could not build coordinator: \(error)")
}

let creatorID = "youtube:handle:@hermitcraft"
let videoTitle = "Season 11 base tour: storage room and a new redstone farm"

var catalog = coordinator.snapshot().workspaceCatalog
let tree = TagTreeAsset(id: "topics", name: "Topics", nodes: [
    .init(id: "gaming", name: "Gaming"),
    .init(id: "music", name: "Music"),
    .init(id: "politics", name: "Politics"),
    .init(id: "tech", name: "Technology"),
    .init(id: "cooking", name: "Cooking"),
    .init(id: "sports", name: "Sports"),
])
catalog.trees.append(tree)

guard let binding = catalog.bindings.first(where: { $0.id == "youtube" }),
      let datasetIndex = catalog.datasets.firstIndex(where: { $0.id == binding.datasetID }) else {
    fail("error: starter catalog is missing a youtube binding/dataset")
}
let dataset = catalog.datasets[datasetIndex]
catalog.classifierTypes.append(ClassifierTypeAsset(
    id: "type", name: "YT topics", treeID: tree.id, treeRevision: tree.revision,
    datasetID: dataset.id, datasetRevision: dataset.revision, applicablePlatformID: "youtube"
))
catalog.providerProfiles.append(geminiProfile)
_ = catalog.datasets[datasetIndex].upsertCollectedEntry(.init(
    id: "row1", platformID: "youtube", entryID: "vid1", creatorID: creatorID,
    creatorName: "HermitCraft", entryType: "video", title: videoTitle
))

do { try coordinator.updateWorkspaceCatalog(catalog) }
catch { fail("error: seeding catalog failed: \(error)") }

// Research: provider-grounding via the saved Gemini provider. A creator score
// threshold of 0.5 makes the first untaggable video fire creator research — so
// the loop is deterministic: the creator is always researched, keyed, and then
// consulted on re-classification. (Production defaults are score 3 / half-life 14 days.)
do {
    try coordinator.updateSettings(ClassifierSettings(research: ResearchSettings(
        enabled: true,
        llmProviderProfileID: geminiProfile.id,
        llmModelIdentifier: APIKeyProviderType.gemini.defaultModelIdentifier,
        requestsPerMinute: 30,
        dailyTokenLimit: 200_000,
        authorThreshold: .init(score: 0.5, halfLifeDays: 14)
    )))
} catch { fail("error: research settings failed: \(error)") }

// MARK: - Real engine + real research queue

stage(1, "loading on-device engine")
let engine: VaultLocalLLMEngine
do {
    engine = try VaultLocalLLMEngine(modelPath: modelPath)
} catch { fail("error: engine load failed: \(error)") }
coordinator.setOnDeviceLLM(engine)
coordinator.setOnDeviceLLMEngineResolver(nil)
line("engine loaded ✓")

func queueConfiguration(for classifierTypeID: String) -> GroundedResearchQueueConfiguration? {
    let state = coordinator.snapshot()
    let r = state.settings.research
    guard r.enabled, let pid = r.llmProviderProfileID, let model = r.llmModelIdentifier,
          let profile = state.workspaceCatalog.providerProfiles.first(where: { $0.id == pid }),
          GroundedGenerationProtocol.supportsProviderGrounding(profile: profile),
          let key = profile.credential else { return nil }
    let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
    let credential = descriptor.credentialFields.first
        .map { ProviderCredentialRecord(values: [$0: key]) } ?? ProviderCredentialRecord(values: [:])
    return GroundedResearchQueueConfiguration(
        providers: .init(
            llmProfile: profile,
            llmCredential: credential,
            llmModelIdentifier: model
        ),
        requestsPerMinute: r.requestsPerMinute,
        dailyTokenLimit: r.dailyTokenLimit,
        failureCooldownMilliseconds: Int64(r.cooldownHours) * 60 * 60 * 1_000
    )
}

let queue = GroundedResearchQueue(
    executor: GroundedResearchExecutor(http: URLSessionProviderHTTPClient()),
    configurationProvider: { task in queueConfiguration(for: task.classifierTypeID) },
    snapshotProvider: { task in coordinator.groundedResearchQueueSnapshot(for: task) },
    mutationWriter: { mutation in await coordinator.recordResearchMutation(mutation) }
)
coordinator.setGroundedResearchQueue(queue)
coordinator.setOnVideoReclassified { platformID, entryID, projection in
    print("  ↳ reclassified \(platformID)/\(entryID) → tags \(projection.tags.map(\.id))")
}

// MARK: - Drive the loop

stage(2, "classify the video (content-only primary decode)")
line("creator: \(creatorID)")
line("title:   \(videoTitle)")
let projection: VideoTagsProjection
do {
    projection = try await coordinator.classifyVideo(
        platformID: "youtube", entryID: "vid1", creatorID: creatorID, title: videoTitle
    )
} catch { fail("error: classifyVideo failed: \(error)") }

let firstRow = coordinator.snapshot().workspaceCatalog
    .videoClassification(classifierTypeID: "type", platformID: "youtube", entryID: "vid1")
line("initial tags:  \(projection.tags.map(\.id))")
line("initial source: \(firstRow?.source.rawValue ?? "?")")

stage(3, "grounded research (real Gemini) — waiting for the creator to be keyed")
var keyedCreator: KnowledgeEntry?
for attempt in 1...120 {
    let cat = coordinator.snapshot().workspaceCatalog
    if let creator = cat.creatorKnowledgeEntry(for: creatorID) { keyedCreator = creator; break }
    if attempt % 10 == 0 { line("  …still researching (\(attempt)s), terms so far: \(cat.knowledgeEntries.count)") }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}

guard let creator = keyedCreator else {
    let cat = coordinator.snapshot().workspaceCatalog
    line("attempts: creators=\(cat.creatorKnowledge.count) terms=\(cat.knowledgeEntries.count) failedAttempts=\(cat.researchAttempts.count)")
    fail("error: creator was not keyed within the timeout (check dev.log for research errors)")
}
line("creator keyed ✓")
line("description: \(creator.meaning)")
line("sources: \(creator.sourceURLs.count)")

let termEntries = coordinator.snapshot().workspaceCatalog.knowledgeEntries
if let term = termEntries.first {
    line("\nalso keyed term \"\(term.subject)\": \(term.meaning.prefix(160))…")
}

stage(4, "re-classify with the creator description in play")
// Give the fire-and-forget reclassify a moment to land, then read the stored row.
try? await Task.sleep(nanoseconds: 1_500_000_000)
let finalRow = coordinator.snapshot().workspaceCatalog
    .videoClassification(classifierTypeID: "type", platformID: "youtube", entryID: "vid1")
line("final tags:   \((finalRow?.tags ?? []).map { "\($0.tagID)@\($0.confidence)" })")
line("final source: \(finalRow?.source.rawValue ?? "?")")
line("knowledgeRefs: \(finalRow?.knowledgeRefs ?? [])")

// Also run one explicit re-classify to show the creator-grounded path directly.
let regrounded = try? await coordinator.classifyVideo(
    platformID: "youtube", entryID: "vid1", creatorID: creatorID, title: videoTitle
)
line("\nexplicit re-classify → tags \((regrounded?.tags ?? []).map(\.id)), source \(coordinator.snapshot().workspaceCatalog.videoClassification(classifierTypeID: "type", platformID: "youtube", entryID: "vid1")?.source.rawValue ?? "?")")

await queue.waitUntilIdle()
line("\n✓ full loop complete.")
try? FileManager.default.removeItem(at: tempRoot)
