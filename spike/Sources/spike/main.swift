import Foundation
import MLXLLM
import MLXLMCommon

// Phase 0 latency spike: does a small on-device LLM classify a title into a few
// tags within budget (< 500 ms fine / 500 ms–1 s danger / > 1 s reject)?
// Measures a prefix-cached, short generation per title.
//
// NOTE: mlx-swift-examples' generate API shifts between versions. If this doesn't
// compile against the resolved `main`, adjust the `generate` call to the pinned
// version's signature — the structure (load once, time N generations) is stable.
// This lives in `main.swift`, so it uses top-level `await` (no `@main`).

let modelID = CommandLine.arguments.dropFirst().first ?? "mlx-community/Llama-3.2-1B-Instruct-4bit"

let staticPrefix = """
You are a tagging model. Classify a single video into tags from the taxonomy below.
Reply with one JSON object only: {"tags":[{"name":"<tag>","confidence":<1-5>}],"unknownTerms":["<term>"]}.
Taxonomy:
- Politics: government, policy, geopolitics
- Gaming: video games, esports
- Minecraft (under Gaming): the game Minecraft
- Technology: software, hardware, science
"""

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

func middle(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : values.sorted()[values.count / 2]
}

do {
    print("Loading \(modelID) …")
    let loadStart = Date()
    let container = try await LLMModelFactory.shared.loadContainer(
        configuration: ModelConfiguration(id: modelID)
    )
    print(String(format: "Loaded in %.1fs", Date().timeIntervalSince(loadStart)))

    var perTitleMs: [Double] = []
    for (index, title) in titles.enumerated() {
        let prompt = staticPrefix + "\n\nVideo:\nTitle: \(title)\nOutput JSON:"
        let start = Date()
        _ = try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
            return try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 48, temperature: 0.0),
                context: context
            ) { (_: [Int]) in .more }
        }
        let ms = Date().timeIntervalSince(start) * 1000
        if index > 0 { perTitleMs.append(ms) }  // exclude warm-up
        print(String(format: "  %6.1f ms  |  %@", ms, title))
    }

    if let median = middle(perTitleMs) {
        let band = median < 500 ? "GREEN (<500ms)" : (median <= 1000 ? "DANGER (500ms-1s)" : "REJECT (>1s)")
        print(String(format: "\nMedian (excl. warm-up): %.1f ms  ->  %@", median, band))
    }
} catch {
    print("Spike failed: \(error)")
    print("If this is an API mismatch, adjust the generate() call to the resolved mlx-swift-examples version.")
    exit(1)
}
