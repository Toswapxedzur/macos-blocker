import Foundation
import VaultClassifierCore
import VaultClassifierLLM
import Vision
import AppKit

// On-device Vision OCR of a YouTube thumbnail (hqdefault), so `score --ocr`
// measures the thumbnail-text-evidence path the same way the app runs it.
func ocrThumbnail(entryID: String) -> String? {
    let parts = entryID.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "youtube", parts[1] == "video" else { return nil }
    guard let url = URL(string: "https://i.ytimg.com/vi/\(parts[2])/hqdefault.jpg"),
          let data = try? Data(contentsOf: url), let img = NSImage(data: data),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    var out: String?
    let sem = DispatchSemaphore(value: 0)
    let req = VNRecognizeTextRequest { r, _ in
        let lines = (r.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
        out = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        sem.signal()
    }
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) } catch { sem.signal() }
    sem.wait()
    return (out?.isEmpty == false) ? String(out!.prefix(800)) : nil
}

// Classification accuracy eval harness.
//
//   sample <N> [out.json]   pull N collected videos into a blind labeling sheet
//   score  <in.json>        run the real engine/pipeline on your labels and print
//                           precision/recall per tag + an FP-by-confidence table
//
// Reads the app's own state for the current environment
// (ADAMANCIA_VAULT_ENVIRONMENT=development uses the dev classifier + 3B model),
// so `score` measures the ACTUAL deployed classifier — re-run it after any
// change (conf floor, decline bias, model swap) to see the number move.

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { die("usage: VaultClassifierEval sample <N> [out.json] | score <in.json>") }

let environment = VaultRuntimeEnvironment.current
guard let directory = try? environment.classifierSupportDirectoryURL() else { die("no support directory") }
let stateURL = directory.appendingPathComponent("state.json", isDirectory: false)
guard let state = try? LocalStateFile(url: stateURL).load() else { die("could not load state.json at \(stateURL.path)") }
let catalog = state.workspaceCatalog

// The evaluated classifier type + its tree (first youtube type, or the first type).
guard let type = catalog.classifierTypes.first(where: { $0.applicablePlatformID == "youtube" })
        ?? catalog.classifierTypes.first,
      let tree = catalog.trees.first(where: { $0.id == type.treeID && $0.revision == type.treeRevision })
else { die("no classifier type / bound tree in state") }
let tagNameByID = Dictionary(tree.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
let tagIDByName = Dictionary(tree.nodes.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
let allowedNames = tree.nodes.filter { !$0.isRetired }.map(\.name).sorted()

// The house rules PRODUCTION would use for this type — identical to the
// coordinator's `effectiveHouseRules`: a type's own rules replace the global
// ones, and a legacy LLM-written "Learned preferences" block is stripped. The
// harness used to pass the type's rules RAW, so every eval ran with that stale,
// fabricated block ("Samsung products → Sports") still in the prompt while the
// real app had been stripping it since 5ca3ff7. `--raw-house-rules` restores the
// old behaviour to reproduce earlier numbers.
let productionHouseRules: String? = {
    let perType = type.localModelOverrides?.houseRules
    let global = state.settings.localLLM.houseRules
    if args.contains("--raw-house-rules") { return perType ?? global }
    let manualPerType = CorrectionDistiller.manualRules(from: perType)
    if !manualPerType.isEmpty { return manualPerType }
    let trimmed = global.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}()
if CorrectionDistiller.containsLearnedPreferences(type.localModelOverrides?.houseRules) {
    FileHandle.standardError.write(Data("• note: this type still stores a legacy \"Learned preferences\" block; \(args.contains("--raw-house-rules") ? "KEEPING it (--raw-house-rules)" : "stripped, as production does").\n".utf8))
}

struct EvalItem: Codable {
    var entryID: String
    var creatorID: String
    var title: String
    var trueTags: [String]   // human fills these with tag names (empty = "no tag")
}
struct EvalSet: Codable {
    var treeID: String
    var treeRevision: Int
    var allowedTags: [String]
    var items: [EvalItem]
}

switch command {
case "sample":
    let n = args.count > 1 ? (Int(args[1]) ?? 100) : 100
    let out = args.count > 2 ? args[2] : "eval-set.json"
    // Deterministic stride sample over collected videos with titles (reproducible).
    let entries = catalog.datasets.flatMap(\.collectedEntries)
        .filter { $0.platformID == "youtube" && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        .sorted { $0.entryID < $1.entryID }
    guard !entries.isEmpty else { die("no collected youtube videos to sample") }
    let stride = max(1, entries.count / max(1, n))
    var picked: [EvalItem] = []
    var index = 0
    while index < entries.count && picked.count < n {
        let entry = entries[index]
        picked.append(.init(entryID: entry.entryID, creatorID: entry.creatorID, title: entry.title, trueTags: []))
        index += stride
    }
    let set = EvalSet(treeID: tree.id, treeRevision: tree.revision, allowedTags: allowedNames, items: picked)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(set).write(to: URL(fileURLWithPath: out))
    print("• wrote \(picked.count) blind items to \(out)")
    print("• label each item's \"trueTags\" from: \(allowedNames.joined(separator: ", "))")
    print("  (leave [] when no tag applies). Then: VaultClassifierEval score \(out)")

case "score":
    let verbose = args.contains("-v") || args.contains("--dump")
    let useOcr = args.contains("--ocr")
    let leafOnly = args.contains("--leaf-only")
    let maxOverride = args.compactMap { $0.hasPrefix("--max=") ? Int($0.dropFirst(6)) : nil }.first
    guard args.count > 1, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          let set = try? JSONDecoder().decode(EvalSet.self, from: data) else { die("could not read eval set") }
    // Default: all items, an empty trueTags counting as "should decline". The schema
    // cannot tell an UNLABELED item from a true no-tag one, so `--labeled-only`
    // scores just the items that carry ≥1 label (no reward for merely declining).
    let labeled = args.contains("--labeled-only") ? set.items.filter { !$0.trueTags.isEmpty } : set.items
    guard labeled.contains(where: { !$0.trueTags.isEmpty }) else { die("no items labeled yet — fill in trueTags") }

    let modelOverride = args.compactMap { $0.hasPrefix("--model=") ? String($0.dropFirst(8)) : nil }.first
    guard let modelPath = modelOverride ?? VaultLocalLLMEngine.defaultModelPath(preferredFileName: state.settings.localLLM.modelFileName) else {
        die("no .gguf model found for this environment")
    }
    let engine: VaultLocalLLMEngine
    do { engine = try VaultLocalLLMEngine(modelPath: modelPath) } catch { die("engine load failed: \(error)") }
    print("• model: \((modelPath as NSString).lastPathComponent)  •  \(labeled.count) items  •  type \"\(type.name)\"\n")

    let settings = state.settings.localLLM
    let research = state.settings.research
    let overrides = type.localModelOverrides
    let maxTags = maxOverride ?? settings.maximumTags
    let forceTag = args.contains("--no-decline")   // min-1: the model may not decline
    let priorRows = args.compactMap { $0.hasPrefix("--prior-rows=") ? Int($0.dropFirst(13)) : nil }.first
    let minTags = args.compactMap { $0.hasPrefix("--min=") ? Int($0.dropFirst(6)) : nil }.first ?? 0
    let pipeline = VideoClassificationPipeline(llm: engine, maximumTags: maxTags, minimumTags: minTags, creatorPriorRowLimit: priorRows)

    // Optional leaf-only tree: drop every node that has children, so the grammar
    // can never emit a broad parent bucket (Gaming/Technology/Entertainment/Lifestyle).
    var evalTree = tree
    if leafOnly {
        let parentIDs = Set(tree.nodes.compactMap(\.parentID))
        evalTree.nodes = tree.nodes.filter { !parentIDs.contains($0.id) }
    }
    print("• config: leafOnly=\(leafOnly)  maxTags=\(maxTags)  allowedTags=\(evalTree.nodes.filter { !$0.isRetired }.count)\n")

    var tp: [String: Int] = [:], fp: [String: Int] = [:], fn: [String: Int] = [:]
    var exact = 0, declineTrue = 0, declineRight = 0, predictedDeclines = 0
    var fpByConf: [Int: Int] = [:], tpByConf: [Int: Int] = [:]
    var predConfByID: [String: Int] = [:]

    for item in labeled {
        let truth = Set(item.trueTags.compactMap { tagIDByName[$0.lowercased()] })
        let ocrText = useOcr ? ocrThumbnail(entryID: item.entryID) : nil
        if useOcr && verbose { FileHandle.standardError.write(Data("[ocr] \(item.entryID): \(ocrText?.prefix(60) ?? "nil")\n".utf8)) }
        let result = try await pipeline.classify(
            title: item.title, text: ocrText, entryID: item.entryID, creatorID: item.creatorID, platformID: "youtube",
            classifierType: type, tree: evalTree, catalog: catalog,
            houseRules: productionHouseRules,
            allowDecline: forceTag ? false : (overrides?.allowDecline ?? settings.allowDecline),
            confidenceThresholds: overrides?.confidenceThresholds ?? settings.confidenceThresholds,
            knowledgeTTLDays: research.knowledgeTTLDays,
            maxKnowledgePerVideo: research.maxKnowledgePerVideo
        )
        let predicted = Set(result.tags.map(\.tagID))
        for tag in result.tags { predConfByID[tag.tagID] = tag.confidence }

        if verbose {
            let predStr = result.tags.isEmpty ? "— (declined)"
                : result.tags.map { "\(tagNameByID[$0.tagID] ?? $0.tagID)·c\($0.confidence)" }.joined(separator: ", ")
            let truthStr = item.trueTags.isEmpty ? "[]" : item.trueTags.joined(separator: "/")
            let mark = predicted == truth ? "✓" : "✗"
            print(String(format: "%@ %-52@ pred: %-34@ truth: %@", mark, String(item.title.prefix(52)) as NSString, predStr as NSString, truthStr))
        }

        if predicted.isEmpty { predictedDeclines += 1 }
        if truth.isEmpty { declineTrue += 1; if predicted.isEmpty { declineRight += 1 } }
        if predicted == truth { exact += 1 }
        for id in predicted.intersection(truth) { tp[id, default: 0] += 1; tpByConf[predConfByID[id] ?? 0, default: 0] += 1 }
        for id in predicted.subtracting(truth) { fp[id, default: 0] += 1; fpByConf[predConfByID[id] ?? 0, default: 0] += 1 }
        for id in truth.subtracting(predicted) { fn[id, default: 0] += 1 }
    }

    func rate(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
    let allIDs = Set(tp.keys).union(fp.keys).union(fn.keys)
    print("tag                         P     R    F1    (tp/fp/fn)")
    for id in allIDs.sorted(by: { (tagNameByID[$0] ?? $0) < (tagNameByID[$1] ?? $1) }) {
        let t = tp[id] ?? 0, f = fp[id] ?? 0, n = fn[id] ?? 0
        let p = rate(t, t + f), r = rate(t, t + n), f1 = (p + r) == 0 ? 0 : 2 * p * r / (p + r)
        print(String(format: "%-24@  %.2f  %.2f  %.2f   (%d/%d/%d)", (tagNameByID[id] ?? id) as NSString, p, r, f1, t, f, n))
    }
    let TP = tp.values.reduce(0, +), FP = fp.values.reduce(0, +), FN = fn.values.reduce(0, +)
    let microP = rate(TP, TP + FP), microR = rate(TP, TP + FN)
    print(String(format: "\nMICRO  precision %.2f  recall %.2f  F1 %.2f", microP, microR, (microP + microR) == 0 ? 0 : 2 * microP * microR / (microP + microR)))
    print(String(format: "exact-set match: %d/%d (%.0f%%)   decline: %d/%d correct   predicted-declines: %d   format: %@", exact, labeled.count, 100 * rate(exact, labeled.count), declineRight, declineTrue, predictedDeclines, ClassificationReplyFormat.current.id))
    print("\n=== the conf≤2 hypothesis: where do the false positives sit? ===")
    for c in 1...5 {
        let f = fpByConf[c] ?? 0, t = tpByConf[c] ?? 0
        print(String(format: "  conf%d  correct %-4d  WRONG %-4d  (precision %.2f)", c, t, f, rate(t, t + f)))
    }

case "abtest":
    // Grounded-generalization A/B: does injecting the user's own past corrections
    // as per-video retrieval exemplars improve accuracy? Leave-one-out — every
    // labeled item is seeded as a correction, and the retriever excludes each
    // test item's OWN correction by entryID, so a video is only ever helped by
    // OTHER corrections (same creator, or lexically similar title). Arm A runs
    // with an empty correction store; Arm B with the full pool. Everything else
    // (model, tree, house rules, thresholds) is identical between arms.
    guard args.count > 1, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          let set = try? JSONDecoder().decode(EvalSet.self, from: data) else { die("could not read eval set") }
    let labeled = set.items
    guard labeled.contains(where: { !$0.trueTags.isEmpty }) else { die("no items labeled yet — fill in trueTags") }
    let verbose = args.contains("-v") || args.contains("--dump")

    let modelOverride = args.compactMap { $0.hasPrefix("--model=") ? String($0.dropFirst(8)) : nil }.first
    guard let modelPath = modelOverride ?? VaultLocalLLMEngine.defaultModelPath(preferredFileName: state.settings.localLLM.modelFileName) else {
        die("no .gguf model found for this environment")
    }
    let engine: VaultLocalLLMEngine
    do { engine = try VaultLocalLLMEngine(modelPath: modelPath) } catch { die("engine load failed: \(error)") }

    let settings = state.settings.localLLM
    let research = state.settings.research
    let overrides = type.localModelOverrides
    let maxTags = args.compactMap { $0.hasPrefix("--max=") ? Int($0.dropFirst(6)) : nil }.first ?? settings.maximumTags
    let floor = args.compactMap { $0.hasPrefix("--floor=") ? Double($0.dropFirst(8)) : nil }.first ?? CorrectionRetriever.defaultMinimumSimilarity
    let pipeline = VideoClassificationPipeline(llm: engine, maximumTags: maxTags, correctionSimilarityFloor: floor)
    let evalTree = tree

    // The correction pool: every labeled item as an on-taxonomy correction.
    let pool: [CorrectionExample] = labeled.compactMap { item in
        let ids = item.trueTags.compactMap { tagIDByName[$0.lowercased()] }
        // A decline-truth item (no tags) is a valid "no tag" correction exemplar.
        guard item.trueTags.isEmpty || !ids.isEmpty else { return nil }
        return CorrectionExample(
            classifierTypeID: type.id, platformID: "youtube", entryID: item.entryID,
            creatorID: item.creatorID, title: item.title, correctTagIDs: ids
        )
    }
    print("• model: \((modelPath as NSString).lastPathComponent)  •  \(labeled.count) items  •  pool \(pool.count) corrections  •  floor \(String(format: "%.3f", floor))  •  type \"\(type.name)\"\n")

    func classifyItem(_ item: EvalItem, corrections: [CorrectionExample]) async throws -> Set<String> {
        var c = catalog
        c.correctionExamples = corrections
        let r = try await pipeline.classify(
            title: item.title, entryID: item.entryID, creatorID: item.creatorID, platformID: "youtube",
            classifierType: type, tree: evalTree, catalog: c,
            houseRules: productionHouseRules,
            allowDecline: overrides?.allowDecline ?? settings.allowDecline,
            confidenceThresholds: overrides?.confidenceThresholds ?? settings.confidenceThresholds,
            knowledgeTTLDays: research.knowledgeTTLDays,
            maxKnowledgePerVideo: research.maxKnowledgePerVideo
        )
        return Set(r.tags.map(\.tagID))
    }

    var baseExact = 0, groundedExact = 0
    var baseExactFired = 0, groundedExactFired = 0, firedCount = 0
    var wins: [(String, [String])] = [], regressions: [(String, [String])] = []

    for item in labeled {
        let truth = Set(item.trueTags.compactMap { tagIDByName[$0.lowercased()] })
        let fired = CorrectionRetriever.retrieve(
            title: item.title, creatorID: item.creatorID, excludingEntryID: item.entryID,
            from: pool, tree: evalTree, minimumSimilarity: floor
        )
        let base = try await classifyItem(item, corrections: [])
        let grounded = try await classifyItem(item, corrections: pool)
        let baseOK = base == truth, groundedOK = grounded == truth
        if baseOK { baseExact += 1 }
        if groundedOK { groundedExact += 1 }
        if !fired.isEmpty {
            firedCount += 1
            if baseOK { baseExactFired += 1 }
            if groundedOK { groundedExactFired += 1 }
            let exemplarLabels = fired.map { "\"\($0.title.prefix(28))\"→\($0.tagNames.isEmpty ? "none" : $0.tagNames.joined(separator: ","))" }
            if !baseOK && groundedOK { wins.append((item.title, exemplarLabels)) }
            if baseOK && !groundedOK { regressions.append((item.title, exemplarLabels)) }
        }
        if verbose {
            let mark = base == grounded ? " " : (groundedOK ? "▲" : (baseOK ? "▼" : "≠"))
            let names = { (s: Set<String>) in s.isEmpty ? "—" : s.map { tagNameByID[$0] ?? $0 }.sorted().joined(separator: ",") }
            print(String(format: "%@ fired:%d  base:%-16@ grounded:%-16@ truth:%@  | %@", mark, fired.count,
                         names(base) as NSString, names(grounded) as NSString,
                         (truth.isEmpty ? "[]" : truth.map { tagNameByID[$0] ?? $0 }.sorted().joined(separator: ",")),
                         String(item.title.prefix(46))))
        }
    }

    func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.0f%% (%d/%d)", 100 * Double(a) / Double(b), a, b) }
    print("\n=== grounded generalization A/B (leave-one-out) ===")
    print("ALL items       baseline \(pct(baseExact, labeled.count))   grounded \(pct(groundedExact, labeled.count))   Δ \(groundedExact - baseExact)")
    print("retrieval FIRED baseline \(pct(baseExactFired, firedCount))   grounded \(pct(groundedExactFired, firedCount))   Δ \(groundedExactFired - baseExactFired)")
    print("  (retrieval surfaced ≥1 exemplar for \(firedCount)/\(labeled.count) items; the rest are unaffected by design)")
    print("\nwins (baseline wrong → grounded right): \(wins.count)")
    for (t, ex) in wins.prefix(20) { print("  ▲ \(t.prefix(50))\n      via \(ex.joined(separator: "  "))") }
    print("\nregressions (baseline right → grounded wrong): \(regressions.count)")
    for (t, ex) in regressions.prefix(20) { print("  ▼ \(t.prefix(50))\n      via \(ex.joined(separator: "  "))") }

case "calib":
    // RESEARCH-REDESIGN Phase 0, Experiment 1: does model-EMITTED confidence beat
    // the production first-token SOFTMAX confidence? One structured decode per
    // video yields both signals for the same tag choices, so this is a fair
    // head-to-head. We score each emitted tag as correct (in truth) or wrong, bin
    // by each confidence level, and report precision-by-level + ECE for both.
    // The winner decides §6's off-ramp (keep softmax, or adopt model confidence).
    guard args.count > 1, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          let set = try? JSONDecoder().decode(EvalSet.self, from: data) else { die("could not read eval set") }
    // Calibration needs KNOWN truth per item, and this schema can't tell an
    // unlabeled item (trueTags omitted) from a genuine "no tag" one — so restrict
    // to items that were actually labeled with ≥1 tag. Pass --with-declines to
    // also include trueTags=[] rows as true-decline evidence.
    let includeDeclines = args.contains("--with-declines")
    let labeled = includeDeclines ? set.items : set.items.filter { !$0.trueTags.isEmpty }
    guard labeled.contains(where: { !$0.trueTags.isEmpty }) else { die("no items labeled yet — fill in trueTags") }
    let verbose = args.contains("-v") || args.contains("--dump")

    let modelOverride = args.compactMap { $0.hasPrefix("--model=") ? String($0.dropFirst(8)) : nil }.first
    guard let modelPath = modelOverride ?? VaultLocalLLMEngine.defaultModelPath(preferredFileName: state.settings.localLLM.modelFileName) else {
        die("no .gguf model found for this environment")
    }
    let engine: VaultLocalLLMEngine
    do { engine = try VaultLocalLLMEngine(modelPath: modelPath) } catch { die("engine load failed: \(error)") }

    let settings = state.settings.localLLM
    let research = state.settings.research
    let overrides = type.localModelOverrides
    // Default cap 3 so multi-tag videos populate the lower-confidence bins; the
    // production gate is intentionally NOT applied — calibration needs raw tags.
    let maxTags = args.compactMap { $0.hasPrefix("--max=") ? Int($0.dropFirst(6)) : nil }.first ?? 3
    let pipeline = VideoClassificationPipeline(llm: engine, maximumTags: maxTags)
    print("• model: \((modelPath as NSString).lastPathComponent)  •  \(labeled.count) labeled items  •  maxTags \(maxTags)  •  type \"\(type.name)\"\n")

    // Per confidence LEVEL (1–5): how many emitted tags landed there, and how many
    // were correct. Kept separately for the model's digit and the softmax level.
    var modelN = [Int: Int](), modelHit = [Int: Int]()
    var softN = [Int: Int](), softHit = [Int: Int]()
    var declined = 0, emittedTags = 0

    for item in labeled {
        let truth = Set(item.trueTags.compactMap { tagIDByName[$0.lowercased()] })
        let parts = pipeline.primaryPromptParts(
            title: item.title, entryID: item.entryID, creatorID: item.creatorID, platformID: "youtube",
            classifierType: type, tree: tree, catalog: catalog,
            houseRules: productionHouseRules,
            knowledgeTTLDays: research.knowledgeTTLDays,
            maxKnowledgePerVideo: research.maxKnowledgePerVideo
        )
        let result = try await engine.classifyWithModelConfidence(LLMClassificationRequest(
            staticPrefix: parts.staticPrefix,
            dynamicSuffix: parts.dynamicSuffix,
            allowedTagNames: parts.allowedTagNames,
            maximumTags: maxTags,
            allowDecline: overrides?.allowDecline ?? settings.allowDecline,
            confidenceThresholds: overrides?.confidenceThresholds ?? settings.confidenceThresholds
        ))
        if result.tags.isEmpty { declined += 1 }
        for tag in result.tags {
            guard let tagID = parts.nameToTagID[tag.name] else { continue }
            emittedTags += 1
            let correct = truth.contains(tagID) ? 1 : 0
            modelN[tag.modelConfidence, default: 0] += 1; modelHit[tag.modelConfidence, default: 0] += correct
            softN[tag.softmaxConfidence, default: 0] += 1; softHit[tag.softmaxConfidence, default: 0] += correct
            if verbose {
                let mark = correct == 1 ? "✓" : "✗"
                print(String(format: "%@ %-28@ model c%d  soft c%d (p=%.2f)  | %@",
                             mark, tag.name as NSString, tag.modelConfidence, tag.softmaxConfidence,
                             tag.softmaxProbability, String(item.title.prefix(40))))
            }
        }
    }

    // Representative probability for each 1–5 level, so both signals get an ECE.
    let levelProbability: [Int: Double] = [1: 0.1, 2: 0.3, 3: 0.5, 4: 0.7, 5: 0.9]
    func report(_ label: String, _ n: [Int: Int], _ hit: [Int: Int]) {
        print("\n=== \(label) — precision by confidence level ===")
        print("level    n    correct   precision   (target p)")
        var ece = 0.0, total = 0, monotoneOK = true, lastPrecision = -1.0
        for level in 1...5 { total += n[level] ?? 0 }
        for level in 1...5 {
            let count = n[level] ?? 0, correct = hit[level] ?? 0
            let precision = count == 0 ? 0 : Double(correct) / Double(count)
            let target = levelProbability[level] ?? 0
            if count > 0 { ece += Double(count) / Double(max(1, total)) * abs(precision - target) }
            if count > 0 { if precision < lastPrecision - 0.001 { monotoneOK = false }; lastPrecision = precision }
            print(String(format: "  c%d  %5d   %5d      %.2f        %.1f", level, count, correct, precision, target))
        }
        // Separation: precision of the top two levels vs the bottom two.
        let hi = (4...5).reduce(0) { $0 + (hit[$1] ?? 0) }, hiN = (4...5).reduce(0) { $0 + (n[$1] ?? 0) }
        let lo = (1...2).reduce(0) { $0 + (hit[$1] ?? 0) }, loN = (1...2).reduce(0) { $0 + (n[$1] ?? 0) }
        let hiP = hiN == 0 ? 0 : Double(hi) / Double(hiN), loP = loN == 0 ? 0 : Double(lo) / Double(loN)
        print(String(format: "  ECE %.3f   monotone %@   high(4-5) p=%.2f (n=%d)   low(1-2) p=%.2f (n=%d)   separation Δ=%.2f",
                     ece, monotoneOK ? "yes" : "NO", hiP, hiN, loP, loN, hiP - loP))
    }
    print("\n\(emittedTags) tags emitted over \(labeled.count) videos  •  \(declined) declined")
    report("MODEL-emitted confidence", modelN, modelHit)
    report("SOFTMAX confidence (production)", softN, softHit)
    print("\nVerdict rule: prefer the signal with lower ECE + monotone precision + larger separation Δ.")

case "needs":
    // RESEARCH-REDESIGN Phase 2, Decode 2 live smoke: run the classification
    // decode, then the research-needs decode over the same KV-cached evidence, and
    // print the emitted terms/urgency + author-urgency. Proves the GBNF compiles
    // in llama.cpp and the model produces sane, copied terms — not measured, just
    // eyeballed. `--limit=N` caps how many videos to run (default 12).
    guard args.count > 1, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          let set = try? JSONDecoder().decode(EvalSet.self, from: data) else { die("could not read eval set") }
    let limit = args.compactMap { $0.hasPrefix("--limit=") ? Int($0.dropFirst(8)) : nil }.first ?? 12
    let items = Array(set.items.filter { !$0.trueTags.isEmpty }.prefix(limit))
    guard !items.isEmpty else { die("no labeled items to run") }

    let modelOverride = args.compactMap { $0.hasPrefix("--model=") ? String($0.dropFirst(8)) : nil }.first
    guard let modelPath = modelOverride ?? VaultLocalLLMEngine.defaultModelPath(preferredFileName: state.settings.localLLM.modelFileName) else {
        die("no .gguf model found for this environment")
    }
    let engine: VaultLocalLLMEngine
    do { engine = try VaultLocalLLMEngine(modelPath: modelPath) } catch { die("engine load failed: \(error)") }

    let settings = state.settings.localLLM
    let research = state.settings.research
    let overrides = type.localModelOverrides
    let maxTerms = args.compactMap { $0.hasPrefix("--terms=") ? Int($0.dropFirst(8)) : nil }.first ?? 3
    let pipeline = VideoClassificationPipeline(llm: engine, maximumTags: settings.maximumTags)
    print("• model: \((modelPath as NSString).lastPathComponent)  •  \(items.count) items  •  maxTerms \(maxTerms)  •  type \"\(type.name)\"\n")

    for item in items {
        let parts = pipeline.primaryPromptParts(
            title: item.title, entryID: item.entryID, creatorID: item.creatorID, platformID: "youtube",
            classifierType: type, tree: tree, catalog: catalog,
            houseRules: productionHouseRules,
            knowledgeTTLDays: research.knowledgeTTLDays,
            maxKnowledgePerVideo: research.maxKnowledgePerVideo
        )
        // Decode 1 first, so Decode 2 reuses its KV-cached evidence prefix.
        let classification = try await engine.classify(LLMClassificationRequest(
            staticPrefix: parts.staticPrefix, dynamicSuffix: parts.dynamicSuffix,
            allowedTagNames: parts.allowedTagNames, maximumTags: settings.maximumTags,
            allowDecline: overrides?.allowDecline ?? settings.allowDecline,
            confidenceThresholds: overrides?.confidenceThresholds ?? settings.confidenceThresholds
        ))
        let terms = try await engine.researchNeeds(LLMResearchNeedsRequest(
            staticPrefix: parts.staticPrefix, dynamicSuffix: parts.dynamicSuffix, maximumTerms: maxTerms
        ))
        // Urgency is DERIVED from the classification confidences (the reliable
        // signal), not asked of the model — same value feeds §8's author accumulator.
        let derivedUrgency = ResearchUrgency.fromTagConfidences(classification.tags.map(\.confidence))
        let tagStr = classification.tags.isEmpty ? "—(declined)"
            : classification.tags.map { "\($0.name)·c\($0.confidence)" }.joined(separator: ", ")
        let termStr = terms.isEmpty ? "(none)" : terms.map { "\"\($0)\"" }.joined(separator: ", ")
        print(String(format: "• %-46@\n    tags: %@\n    terms: %@   derived-urgency: %d",
                     String(item.title.prefix(46)) as NSString, tagStr, termStr, derivedUrgency))
    }

case "latency":
    // RESEARCH-REDESIGN §10 Experiment 3: per-video wall time of Decode 1
    // (structured, model confidence) and Decode 2 (term extraction), steady state.
    // Decode 2 is timed right after Decode 1 (warm KV — the inline cost) — the app
    // currently runs it detached, so this is the best case for moving it inline.
    guard args.count > 1, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          let set = try? JSONDecoder().decode(EvalSet.self, from: data) else { die("could not read eval set") }
    let limit = args.compactMap { $0.hasPrefix("--limit=") ? Int($0.dropFirst(8)) : nil }.first ?? 30
    let items = Array(set.items.prefix(limit))
    let modelOverride = args.compactMap { $0.hasPrefix("--model=") ? String($0.dropFirst(8)) : nil }.first
    guard let modelPath = modelOverride ?? VaultLocalLLMEngine.defaultModelPath(preferredFileName: state.settings.localLLM.modelFileName) else {
        die("no .gguf model found for this environment")
    }
    let engine: VaultLocalLLMEngine
    do { engine = try VaultLocalLLMEngine(modelPath: modelPath) } catch { die("engine load failed: \(error)") }
    let settings = state.settings.localLLM
    let research = state.settings.research
    let overrides = type.localModelOverrides
    let maxTags = args.compactMap { $0.hasPrefix("--max=") ? Int($0.dropFirst(6)) : nil }.first ?? 1
    let pipeline = VideoClassificationPipeline(llm: engine, maximumTags: maxTags)
    var decode1: [Double] = [], decode2: [Double] = []
    for (index, item) in items.enumerated() {
        let parts = pipeline.primaryPromptParts(
            title: item.title, entryID: item.entryID, creatorID: item.creatorID, platformID: "youtube",
            classifierType: type, tree: tree, catalog: catalog,
            houseRules: productionHouseRules,
            knowledgeTTLDays: research.knowledgeTTLDays, maxKnowledgePerVideo: research.maxKnowledgePerVideo
        )
        let t0 = Date()
        _ = try await engine.classify(LLMClassificationRequest(
            staticPrefix: parts.staticPrefix, dynamicSuffix: parts.dynamicSuffix,
            allowedTagNames: parts.allowedTagNames, maximumTags: maxTags,
            allowDecline: overrides?.allowDecline ?? settings.allowDecline,
            confidenceThresholds: overrides?.confidenceThresholds ?? settings.confidenceThresholds
        ))
        let t1 = Date()
        _ = try await engine.researchNeeds(LLMResearchNeedsRequest(
            staticPrefix: parts.staticPrefix, dynamicSuffix: parts.dynamicSuffix, maximumTerms: 3
        ))
        let t2 = Date()
        if index > 0 {   // skip the cold first video (static-prefix prefill)
            decode1.append(t1.timeIntervalSince(t0) * 1_000)
            decode2.append(t2.timeIntervalSince(t1) * 1_000)
        }
    }
    func stats(_ v: [Double]) -> String {
        let s = v.sorted()
        guard !s.isEmpty else { return "n/a" }
        return String(format: "median %.0f ms   p90 %.0f ms   max %.0f ms", s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.9))], s[s.count - 1])
    }
    print("• model: \((modelPath as NSString).lastPathComponent)  •  \(decode1.count) warm videos  •  maxTags \(maxTags)")
    print("Decode 1 (classify, model confidence): \(stats(decode1))")
    print("Decode 2 (term extraction, warm KV):   \(stats(decode2))")
    print("Both:                                  \(stats(zip(decode1, decode2).map { $0 + $1 }))")

case "batch":
    // LATENCY-REFINEMENT Phase 1: the SAME requests decoded serially and then as
    // one multi-sequence batch — must give the same tags+confidence, and we time
    // both. `--limit=N` videos (default 16), `--max=` tag cap (default 1).
    guard args.count > 1, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          let set = try? JSONDecoder().decode(EvalSet.self, from: data) else { die("could not read eval set") }
    let limit = args.compactMap { $0.hasPrefix("--limit=") ? Int($0.dropFirst(8)) : nil }.first ?? 16
    let offset = args.compactMap { $0.hasPrefix("--offset=") ? Int($0.dropFirst(9)) : nil }.first ?? 0
    let items = Array(set.items.dropFirst(offset).prefix(limit))
    let modelOverride = args.compactMap { $0.hasPrefix("--model=") ? String($0.dropFirst(8)) : nil }.first
    guard let modelPath = modelOverride ?? VaultLocalLLMEngine.defaultModelPath(preferredFileName: state.settings.localLLM.modelFileName) else {
        die("no .gguf model found for this environment")
    }
    let engine: VaultLocalLLMEngine
    do { engine = try VaultLocalLLMEngine(modelPath: modelPath) } catch { die("engine load failed: \(error)") }
    let settings = state.settings.localLLM
    let research = state.settings.research
    let overrides = type.localModelOverrides
    let maxTags = args.compactMap { $0.hasPrefix("--max=") ? Int($0.dropFirst(6)) : nil }.first ?? 1
    let priorRows = args.compactMap { $0.hasPrefix("--prior-rows=") ? Int($0.dropFirst(13)) : nil }.first
    let pipeline = VideoClassificationPipeline(llm: engine, maximumTags: maxTags, creatorPriorRowLimit: priorRows)
    let requests = items.map { item -> LLMClassificationRequest in
        let parts = pipeline.primaryPromptParts(
            title: item.title, entryID: item.entryID, creatorID: item.creatorID, platformID: "youtube",
            classifierType: type, tree: tree, catalog: catalog,
            houseRules: productionHouseRules,
            knowledgeTTLDays: research.knowledgeTTLDays, maxKnowledgePerVideo: research.maxKnowledgePerVideo)
        return LLMClassificationRequest(
            staticPrefix: parts.staticPrefix, dynamicSuffix: parts.dynamicSuffix,
            allowedTagNames: parts.allowedTagNames, maximumTags: maxTags,
            allowDecline: overrides?.allowDecline ?? settings.allowDecline,
            confidenceThresholds: overrides?.confidenceThresholds ?? settings.confidenceThresholds)
    }
    if args.contains("--dump") {
        let sorted = requests.sorted { $0.dynamicSuffix.count > $1.dynamicSuffix.count }
        print("dynamic-suffix chars: " + requests.map { String($0.dynamicSuffix.count) }.joined(separator: " "))
        print("---- longest suffix ----\n\(sorted[0].dynamicSuffix)\n---- shortest suffix ----\n\(sorted[sorted.count - 1].dynamicSuffix)\n----")
    }
    _ = try await engine.classify(requests[0])          // warm the static prefix
    func ms(_ a: Date, _ b: Date) -> Double { b.timeIntervalSince(a) * 1_000 }
    let s0 = Date()
    var serial: [LLMClassificationResult] = []
    for request in requests { serial.append(try await engine.classify(request)) }
    let s1 = Date()
    let batched = try await engine.classifyBatch(requests)
    let s2 = Date()
    func show(_ r: LLMClassificationResult) -> String {
        r.tags.isEmpty ? "—" : r.tags.map { "\($0.name)·c\($0.confidence)" }.joined(separator: ",")
    }
    var sameTags = 0, sameAll = 0
    for (index, item) in items.enumerated() {
        let tagsEqual = serial[index].tags.map(\.name) == batched[index].tags.map(\.name)
        let allEqual = tagsEqual && serial[index].tags.map(\.confidence) == batched[index].tags.map(\.confidence)
        if tagsEqual { sameTags += 1 }
        if allEqual { sameAll += 1 }
        if !allEqual {
            print(String(format: "  DIFF %@ | serial %@ | batched %@", String(item.title.prefix(40)) as NSString, show(serial[index]) as NSString, show(batched[index]) as NSString))
        }
    }
    if args.contains("-v") { for (index, item) in items.enumerated() { print("RESULT \(item.entryID) \(show(batched[index]))") } }
    let tagged = serial.filter { !$0.tags.isEmpty }.count
    print("• model: \((modelPath as NSString).lastPathComponent)  •  \(items.count) videos (\(tagged) tagged, \(items.count - tagged) declined)  •  maxTags \(maxTags)")
    print(String(format: "serial : %.0f ms total   (%.0f ms/video)", ms(s0, s1), ms(s0, s1) / Double(items.count)))
    print(String(format: "batched: %.0f ms total   (%.0f ms/video)   speedup ×%.1f", ms(s1, s2), ms(s1, s2) / Double(items.count), ms(s0, s1) / ms(s1, s2)))
    print("equivalence: same tags \(sameTags)/\(items.count)   same tags+confidence \(sameAll)/\(items.count)")

default:
    die("usage: VaultClassifierEval sample <N> [out.json] | score <in.json> | abtest <in.json> | calib <in.json> | needs <in.json> | latency <in.json> | batch <in.json>")
}
