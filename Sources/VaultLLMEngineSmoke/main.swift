import Foundation
import VaultClassifierCore
import VaultClassifierLLM

// Phase-0 benchmark through the REAL in-process engine: same taxonomy, titles,
// and contract as the llama-server spike, so the numbers are directly
// comparable (server baseline on M1 Pro: ~133 ms median per title).
//
//   swift run -c release VaultLLMEngineSmoke [path-to-model.gguf]

let explicitPath = CommandLine.arguments.dropFirst().first
guard let modelPath = explicitPath ?? VaultLocalLLMEngine.defaultModelPath() else {
    print("No model file. Pass a .gguf path or set ADAMANCIA_VAULT_LLM_MODEL.")
    exit(1)
}

let staticPrefix = """
You are a tagging model. Classify a single video into tags from the taxonomy below, using the video's evidence.
Rules:
- Choose only tags that clearly apply; prefer specific child tags over broad parents.
- Assign at most 1 tags.
- For each chosen tag give a confidence from 1 (low) to 5 (high).
- Reply with one JSON object only: {"tags":[{"name":"<tag name>","confidence":<1-5>}]}. Use tag names exactly as written. No prose.
- If no tag clearly applies, use the word none as the name.

Taxonomy:
- Politics: government, policy, geopolitics
- Gaming: video games, esports
- Minecraft (under Gaming): the game Minecraft
- Technology: software, hardware, science
"""

let allowed = ["Politics", "Gaming", "Minecraft", "Technology"]
let titles = [
    "US military industrial complex, explained",
    "HermitCraft season 10 — my first base",
    "Reviewing the new M4 MacBook Pro",
    "Ranked deck speedrun world record",
    "Senate hearing highlights",
    "How transformers actually work",
    "Chill lofi beats to study to",
    "Breaking down the election results",
]

func suffix(for title: String) -> String {
    """
    Video:
    Title: \(title)
    Output JSON: {"tags":[{"name":"
    """
}

do {
    print("Loading \(modelPath) …")
    let loadStart = Date()
    let engine = try VaultLocalLLMEngine(modelPath: modelPath)
    print(String(format: "Loaded in %.1fs (%@)", Date().timeIntervalSince(loadStart), engine.modelVersion))

    var perTitleMs: [Double] = []
    for (index, title) in titles.enumerated() {
        let request = LLMClassificationRequest(
            staticPrefix: staticPrefix,
            dynamicSuffix: suffix(for: title),
            allowedTagNames: allowed,
            maximumTags: 1
        )
        let start = Date()
        let result = try await engine.classify(request)
        let ms = Date().timeIntervalSince(start) * 1000
        if index > 0 { perTitleMs.append(ms) }
        let rendered = result.tags.map { "\($0.name) (conf \($0.confidence))" }.joined(separator: ", ")
        print(String(format: "  %7.1f ms  |  %@  ->  %@", ms, title, rendered.isEmpty ? "(none)" : rendered))
    }

    let sorted = perTitleMs.sorted()
    if !sorted.isEmpty {
        let median = sorted[sorted.count / 2]
        let band = median < 500 ? "GREEN (<500ms)" : (median <= 1000 ? "DANGER (500ms-1s)" : "REJECT (>1s)")
        print(String(format: "\nMedian (excl. warm-up): %.1f ms  ->  %@", median, band))
    }
} catch {
    print("Smoke failed: \(error)")
    exit(1)
}
