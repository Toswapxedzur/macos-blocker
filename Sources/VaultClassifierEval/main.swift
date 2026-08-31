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
    let labeled = set.items.filter { !$0.trueTags.isEmpty || $0.trueTags.isEmpty }  // all; empty = declined truth
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
    let pipeline = VideoClassificationPipeline(llm: engine, maximumTags: maxTags)

    // Optional leaf-only tree: drop every node that has children, so the grammar
    // can never emit a broad parent bucket (Gaming/Technology/Entertainment/Lifestyle).
    var evalTree = tree
    if leafOnly {
        let parentIDs = Set(tree.nodes.compactMap(\.parentID))
        evalTree.nodes = tree.nodes.filter { !parentIDs.contains($0.id) }
    }
    print("• config: leafOnly=\(leafOnly)  maxTags=\(maxTags)  allowedTags=\(evalTree.nodes.filter { !$0.isRetired }.count)\n")

    var tp: [String: Int] = [:], fp: [String: Int] = [:], fn: [String: Int] = [:]
    var exact = 0, declineTrue = 0, declineRight = 0
    var fpByConf: [Int: Int] = [:], tpByConf: [Int: Int] = [:]
    var predConfByID: [String: Int] = [:]

    for item in labeled {
        let truth = Set(item.trueTags.compactMap { tagIDByName[$0.lowercased()] })
        let ocrText = useOcr ? ocrThumbnail(entryID: item.entryID) : nil
        if useOcr && verbose { FileHandle.standardError.write(Data("[ocr] \(item.entryID): \(ocrText?.prefix(60) ?? "nil")\n".utf8)) }
        let result = try await pipeline.classify(
            title: item.title, text: ocrText, entryID: item.entryID, creatorID: item.creatorID, platformID: "youtube",
            classifierType: type, tree: evalTree, catalog: catalog,
            houseRules: overrides?.houseRules ?? settings.houseRules,
            allowDecline: overrides?.allowDecline ?? settings.allowDecline,
            confidenceThresholds: overrides?.confidenceThresholds ?? settings.confidenceThresholds,
            knowledgeTTLDays: research.knowledgeTTLDays,
            maxKnowledgePerVideo: research.maxKnowledgePerVideo,
            creatorGroundingConfidenceFloor: research.confidenceTriggerLevel
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
    print(String(format: "exact-set match: %d/%d (%.0f%%)   decline: %d/%d correct", exact, labeled.count, 100 * rate(exact, labeled.count), declineRight, declineTrue))
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
    let pipeline = VideoClassificationPipeline(llm: engine, maximumTags: maxTags)
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
    print("• model: \((modelPath as NSString).lastPathComponent)  •  \(labeled.count) items  •  pool \(pool.count) corrections  •  type \"\(type.name)\"\n")

    func classifyItem(_ item: EvalItem, corrections: [CorrectionExample]) async throws -> Set<String> {
        var c = catalog
        c.correctionExamples = corrections
        let r = try await pipeline.classify(
            title: item.title, entryID: item.entryID, creatorID: item.creatorID, platformID: "youtube",
            classifierType: type, tree: evalTree, catalog: c,
            houseRules: overrides?.houseRules ?? settings.houseRules,
            allowDecline: overrides?.allowDecline ?? settings.allowDecline,
            confidenceThresholds: overrides?.confidenceThresholds ?? settings.confidenceThresholds,
            knowledgeTTLDays: research.knowledgeTTLDays,
            maxKnowledgePerVideo: research.maxKnowledgePerVideo,
            creatorGroundingConfidenceFloor: research.confidenceTriggerLevel
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
            from: pool, tree: evalTree
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

default:
    die("usage: VaultClassifierEval sample <N> [out.json] | score <in.json> | abtest <in.json>")
}
