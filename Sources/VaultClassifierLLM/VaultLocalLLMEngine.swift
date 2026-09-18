import Foundation
import VaultClassifierCore
import Cllama

// MARK: - Calibration diagnostics (RESEARCH-REDESIGN Phase 0, Experiment 1)

/// One predicted tag carrying BOTH confidence signals from a single structured
/// decode, so the calibration eval can score them head-to-head on the same tag
/// choice: `modelConfidence` is the digit the model emitted (`…,"confidence":N`),
/// `softmaxConfidence` is the production signal (renormalized first-token softmax
/// mapped through the same thresholds). `softmaxProbability` is the raw prob for
/// ECE binning.
public struct LLMCalibrationTag: Sendable, Equatable {
    public let name: String
    public let modelConfidence: Int
    public let softmaxConfidence: Int
    public let softmaxProbability: Double
    public init(name: String, modelConfidence: Int, softmaxConfidence: Int, softmaxProbability: Double) {
        self.name = name
        self.modelConfidence = modelConfidence
        self.softmaxConfidence = softmaxConfidence
        self.softmaxProbability = softmaxProbability
    }
}

public struct LLMCalibrationResult: Sendable, Equatable {
    public let tags: [LLMCalibrationTag]
    public let declined: Bool
    public init(tags: [LLMCalibrationTag], declined: Bool) {
        self.tags = tags
        self.declined = declined
    }
}

// In-process llama.cpp engine implementing the FINAL Phase-0 output contract
// (REWORK decision log, 2026-08-15):
//
// - Grammar-constrained, name-only decode: the GBNF grammar admits exactly one
//   taxonomy tag name (~2 generated tokens), nothing else.
// - The JSON scaffold lives in the (prefilled) prompt as the model's structural
//   runway; it is never generated, so it is never billed at decode rates.
// - Confidence is not generated either: it is the full-vocabulary softmax
//   probability of the first chosen token, mapped onto the 1–5 scale. Measured
//   far better calibrated than self-reported confidence (37% on the
//   no-good-answer case that self-reporting called 4/5).
// - The static prefix's KV cache is reused across requests via longest-common-
//   prefix truncation, so a steady-state request prefills only the per-video
//   suffix. An actor serializes all access to the single llama context.
//
// The model file is user-provided (catalog/loader phase pending): the
// `ADAMANCIA_VAULT_LLM_MODEL` environment variable, or the first *.gguf under
// `<app support>/<environment dir>/models/`.
public actor VaultLocalLLMEngine: OnDeviceBatchLLM, OnDeviceResearchSubjectExtracting, OnDeviceResearchNeedsExtracting {
    public nonisolated let modelVersion: String

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let contextTokenLimit: Int
    private let batchTokenLimit: Int
    /// Videos decoded together in one multi-sequence pass. Generation is
    /// memory-bandwidth-bound (every step re-reads all the weights), so N sequences
    /// per step cost about the same as one — this is the throughput lever.
    public static let maximumParallelSequences = 16
    private let configuration: LocalLLMSettings
    private var cachedTokens: [llama_token] = []

    private static let backendReady: Void = {
        // In a packaged .app the ggml backends (Metal/CPU/BLAS) are bundled in
        // Contents/Frameworks; load them explicitly so we never depend on
        // ggml's compiled-in Homebrew libexec path. In dev/CLI builds that
        // directory doesn't exist, so ggml's own auto-discovery (via
        // llama_backend_init) handles it.
        if let backendDirectory = bundledBackendDirectory() {
            ggml_backend_load_all_from_path(backendDirectory)
        }
        llama_backend_init()
    }()

    /// `<App>.app/Contents/Frameworks` when running from a bundle, else nil.
    private static func bundledBackendDirectory() -> String? {
        let frameworks = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: frameworks.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return frameworks.path
    }

    public enum EngineError: Error, CustomStringConvertible {
        case modelLoadFailed(String)
        case contextCreationFailed

        public var description: String {
            switch self {
            case .modelLoadFailed(let path): return "Could not load GGUF model at \(path)."
            case .contextCreationFailed: return "Could not create a llama context."
            }
        }
    }

    public init(modelPath: String, configuration: LocalLLMSettings = LocalLLMSettings()) throws {
        _ = Self.backendReady
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = configuration.gpuOffload ? 999 : 0
        guard FileManager.default.fileExists(atPath: modelPath),
              let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw EngineError.modelLoadFailed(modelPath)
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(configuration.contextTokens)
        contextParams.n_batch = UInt32(configuration.batchTokens)
        // Batched classification (LATENCY-REFINEMENT Phase 1): seq 0 holds the shared
        // prompt prefix; seqs 1…N decode a screenful of videos in lock-step. A
        // unified KV lets `seq_cp` share the prefix cells instead of copying them.
        contextParams.n_seq_max = UInt32(1 + Self.maximumParallelSequences)
        contextParams.kv_unified = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw EngineError.contextCreationFailed
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.contextTokenLimit = configuration.contextTokens
        self.batchTokenLimit = max(32, configuration.batchTokens)
        self.configuration = configuration
        self.modelVersion = "llamacpp/" + (modelPath as NSString).lastPathComponent
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// Decode 1 (RESEARCH-REDESIGN Phase 2). The structured decode emits the
    /// model's OWN confidence digit per tag — Experiment 1 (2026-09-16) showed it
    /// is better calibrated than the first-token softmax (ECE 0.287 vs 0.353,
    /// monotone, conf≤2 = 0% correct). The softmax level is still computed and
    /// carried as a cheap cross-check on each `LLMTagScore`.
    public func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        let decoded = try await structuredDecode(request)
        return LLMClassificationResult(tags: decoded.tags.map {
            LLMTagScore(name: $0.name, confidence: $0.modelConfidence, softmaxConfidence: $0.softmaxConfidence)
        })
    }

    /// Diagnostic entry point for the calibration eval: the same structured decode
    /// as `classify`, but exposing BOTH raw signals per tag for head-to-head
    /// scoring (`VaultClassifierEval calib`).
    public func classifyWithModelConfidence(_ request: LLMClassificationRequest) async throws -> LLMCalibrationResult {
        let decoded = try await structuredDecode(request)
        return LLMCalibrationResult(tags: decoded.tags, declined: decoded.declined)
    }

    // MARK: - Batched decode (LATENCY-REFINEMENT Phase 1)

    private struct ParallelItem {
        let index: Int                     // position in the caller's request array
        let request: LLMClassificationRequest
        let tokens: [llama_token]
        let grammar: String
        let generationCap: Int
        let allowDecline: Bool
        let candidateFirstTokens: Set<llama_token>
        let thresholds: [Double]
    }

    /// Classifies many videos in lock-step. Same grammar + greedy sampling as the
    /// serial `classify`, so each video gets the answer it would have got alone —
    /// but the weight-read that dominates every generation step is shared by all
    /// of them. Requests are packed into sub-batches that fit the KV budget.
    public func classifyBatch(_ requests: [LLMClassificationRequest]) async throws -> [LLMClassificationResult] {
        var results = [LLMClassificationResult](repeating: .init(tags: []), count: requests.count)
        var items: [ParallelItem] = []
        for (index, request) in requests.enumerated() {
            // No usable names → stays the empty result.
            if let item = try makeParallelItem(index: index, request: request) { items.append(item) }
        }

        // Greedy packing: a sub-batch holds at most `maximumParallelSequences`
        // videos and must fit the KV: shared prefix once + each video's own
        // suffix and generation room.
        var cursor = 0
        while cursor < items.count {
            var group: [ParallelItem] = [items[cursor]]
            cursor += 1
            while cursor < items.count, group.count < Self.maximumParallelSequences {
                let candidate = group + [items[cursor]]
                guard Self.kvCellsNeeded(candidate) + 8 <= contextTokenLimit else { break }
                group = candidate
                cursor += 1
            }
            for (item, decoded) in zip(group, try decodeParallel(group)) {
                results[item.index] = LLMClassificationResult(tags: decoded.tags.map {
                    LLMTagScore(name: $0.name, confidence: $0.modelConfidence, softmaxConfidence: $0.softmaxConfidence)
                })
            }
        }
        return results
    }

    /// The ONE place a request is prepared for decoding — grammar, prompt tokens,
    /// generation budget, decline handling, softmax candidates — shared by the
    /// serial and batched paths so they can never diverge. nil = no usable tag
    /// name (nothing to decode).
    private func makeParallelItem(index: Int, request: LLMClassificationRequest) throws -> ParallelItem? {
        let maximumTags = max(1, request.maximumTags)
        // minimumTags ≥ 1 forbids declining, whatever the allowDecline flag says.
        let allowDecline = (request.allowDecline ?? configuration.allowDecline) && request.minimumTags == 0
        guard let grammar = Self.namesWithConfidenceGrammar(
            allowed: request.allowedTagNames, allowDecline: allowDecline, maximumTags: maximumTags, minimumTags: request.minimumTags
        ) else { return nil }
        let tokens = try tokenize(request.staticPrefix + "\n\n" + request.dynamicSuffix)
        guard tokens.count + 24 <= contextTokenLimit else {
            throw OnDeviceLLMError.inference("prompt-exceeds-context (\(tokens.count) tokens)")
        }
        let candidateNames = allowDecline ? request.allowedTagNames + [Self.declineLiteral] : request.allowedTagNames
        return ParallelItem(
            index: index, request: request, tokens: tokens, grammar: grammar,
            // Bounded by the room left in the context as well as the output budget.
            generationCap: min(
                max(1, contextTokenLimit - tokens.count - 1),
                max(configuration.maximumOutputTokens, maximumTags * 24 + 8)
            ),
            allowDecline: allowDecline,
            candidateFirstTokens: Set(candidateNames.compactMap { try? tokenize($0, addSpecial: false).first }),
            thresholds: request.confidenceThresholds ?? configuration.confidenceThresholds
        )
    }

    private static func sharedPrefixLength(_ items: [ParallelItem]) -> Int {
        guard let first = items.first else { return 0 }
        // Every sequence must keep ≥1 own token to decode, so it ends on fresh logits.
        var length = items.map { $0.tokens.count - 1 }.min() ?? 0
        for item in items.dropFirst() {
            var common = 0
            while common < length, item.tokens[common] == first.tokens[common] { common += 1 }
            length = common
        }
        return max(0, length)
    }

    private static func kvCellsNeeded(_ items: [ParallelItem]) -> Int {
        let prefix = sharedPrefixLength(items)
        return prefix + items.reduce(0) { $0 + ($1.tokens.count - prefix) + $1.generationCap }
    }

    private typealias BatchEntry = (token: llama_token, position: Int32, sequence: Int32, wantsLogits: Bool)

    /// One `llama_decode` over explicit (token, position, sequence) entries.
    private func decode(_ entries: [BatchEntry], using batch: inout llama_batch) -> Int32 {
        for (slot, entry) in entries.enumerated() {
            batch.token[slot] = entry.token
            batch.pos[slot] = entry.position
            batch.n_seq_id[slot] = 1
            batch.seq_id[slot]![0] = entry.sequence
            batch.logits[slot] = entry.wantsLogits ? 1 : 0
        }
        batch.n_tokens = Int32(entries.count)
        return llama_decode(context, batch)
    }

    private func decodeParallel(_ items: [ParallelItem]) throws -> [(tags: [LLMCalibrationTag], declined: Bool)] {
        let timing = ProcessInfo.processInfo.environment["VAULT_DECODE_TIMING"] == "1"
        let tStart = DispatchTime.now()
        let memory = llama_get_memory(context)
        let prefixLength = Self.sharedPrefixLength(items)
        let prefix = Array(items[0].tokens.prefix(prefixLength))
        var batch = llama_batch_init(Int32(batchTokenLimit), 0, 1)
        defer { llama_batch_free(batch) }

        func fail(_ label: String, _ status: Int32) -> OnDeviceLLMError {
            // Unknown KV state → drop everything so the next request starts clean.
            cachedTokens = []
            llama_memory_seq_rm(memory, -1, -1, -1)
            return OnDeviceLLMError.inference("\(label) (\(status))")
        }
        func run(_ entries: [BatchEntry], _ label: String) throws {
            var start = 0
            while start < entries.count {
                let end = min(start + batchTokenLimit, entries.count)
                let status = decode(Array(entries[start..<end]), using: &batch)
                guard status == 0 else { throw fail(label, status) }
                start = end
            }
        }

        // 1. Sequence 0 holds the shared prefix (reusing whatever is already cached).
        var common = 0
        while common < min(prefix.count, cachedTokens.count), prefix[common] == cachedTokens[common] { common += 1 }
        llama_memory_seq_rm(memory, 0, llama_pos(common), -1)
        try run((common..<prefix.count).map { (prefix[$0], Int32($0), 0, false) }, "batch-prefix-decode-failed")
        cachedTokens = prefix

        // 2. Every video's sequence shares those prefix cells, then prefills its own
        //    suffix. The last token of each is held back for one final decode whose
        //    outputs are, in order, each sequence's first-generation logits.
        var suffixEntries: [BatchEntry] = []
        var lastEntries: [BatchEntry] = []
        for (slot, item) in items.enumerated() {
            let sequence = Int32(slot + 1)
            llama_memory_seq_rm(memory, sequence, -1, -1)
            if prefixLength > 0 { llama_memory_seq_cp(memory, 0, sequence, 0, llama_pos(prefixLength)) }
            for position in prefixLength..<(item.tokens.count - 1) {
                suffixEntries.append((item.tokens[position], Int32(position), sequence, false))
            }
            lastEntries.append((item.tokens[item.tokens.count - 1], Int32(item.tokens.count - 1), sequence, true))
        }
        try run(suffixEntries, "batch-suffix-decode-failed")
        try run(lastEntries, "batch-suffix-decode-failed")
        if timing { llama_synchronize(context) }   // Metal is async — stamp after the GPU finishes
        let tPrefill = DispatchTime.now()

        // 3. Lock-step generation: one decode advances every live sequence.
        struct Live {
            var sampler: UnsafeMutablePointer<llama_sampler>
            var outputIndex: Int32
            var length: Int
            var generated = ""
            var generatedTokens = 0
            var nameStartProbabilities: [Double] = []
            var awaitingNameStart = true
            var finished = false
        }
        var live: [Live] = items.enumerated().map { slot, item in
            let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
            llama_sampler_chain_add(sampler, llama_sampler_init_grammar(vocab, item.grammar, "root"))
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
            return Live(sampler: sampler, outputIndex: Int32(slot), length: item.tokens.count)
        }
        defer { for state in live { llama_sampler_free(state.sampler) } }

        var steps = 0
        while true {
            var next: [BatchEntry] = []
            for slot in live.indices where !live[slot].finished {
                let token = llama_sampler_sample(live[slot].sampler, context, live[slot].outputIndex)
                if llama_vocab_is_eog(vocab, token) { live[slot].finished = true; continue }
                if live[slot].awaitingNameStart {
                    live[slot].nameStartProbabilities.append(probability(
                        of: token, among: items[slot].candidateFirstTokens, outputIndex: live[slot].outputIndex))
                    live[slot].awaitingNameStart = false
                }
                live[slot].generated += piece(for: token)
                live[slot].generatedTokens += 1
                // Whatever the grammar now forces rides in THIS step's decode.
                var stepTokens = [token]
                if Self.feedsForcedSpans {
                    let forced = Self.forcedContinuation(
                        after: live[slot].generated, allowedTagNames: items[slot].request.allowedTagNames,
                        allowDecline: items[slot].allowDecline, maximumTags: items[slot].request.maximumTags)
                    if forced.finished { live[slot].finished = true; continue }
                    if !forced.forced.isEmpty, let forcedTokens = try? tokenize(forced.forced, addSpecial: false) {
                        for forcedToken in forcedTokens { llama_sampler_accept(live[slot].sampler, forcedToken) }
                        stepTokens += forcedTokens
                        live[slot].generated += forced.forced
                        live[slot].generatedTokens += forcedTokens.count
                    }
                }
                if live[slot].generated.hasSuffix(Self.structuredSeparator) { live[slot].awaitingNameStart = true }
                if live[slot].generatedTokens >= items[slot].generationCap { live[slot].finished = true; continue }
                for (offset, stepToken) in stepTokens.enumerated() {
                    let isLast = offset == stepTokens.count - 1
                    if isLast { live[slot].outputIndex = Int32(next.count) }
                    next.append((stepToken, Int32(live[slot].length), Int32(slot + 1), isLast))
                    live[slot].length += 1
                }
            }
            guard !next.isEmpty else { break }
            let status = decode(next, using: &batch)
            guard status == 0 else { throw fail("batch-generation-decode-failed", status) }
            steps += 1
        }

        // 4. Release the per-video sequences; sequence 0 keeps the shared prefix.
        for slot in items.indices { llama_memory_seq_rm(memory, Int32(slot + 1), -1, -1) }

        if timing {
            let ms = { (a: DispatchTime, b: DispatchTime) in Double(b.uptimeNanoseconds - a.uptimeNanoseconds) / 1_000_000 }
            let tEnd = DispatchTime.now()
            FileHandle.standardError.write(Data(String(
                format: "[batch-timing] videos=%d prefix=%d (reused %d) suffixTokens=%d  prefill=%.0f  gen=%.0f  steps=%d  genTokens=%d  total=%.0fms\n",
                items.count, prefixLength, common, suffixEntries.count + lastEntries.count, ms(tStart, tPrefill), ms(tPrefill, tEnd), steps,
                live.reduce(0) { $0 + $1.generatedTokens }, ms(tStart, tEnd)
            ).utf8))
        }
        return zip(items, live).map { item, state in
            Self.parseStructuredOutput(
                state.generated, nameStartProbabilities: state.nameStartProbabilities,
                allowedTagNames: item.request.allowedTagNames, thresholds: item.thresholds)
        }
    }

    /// The shared structured decode behind both `classify` and
    /// `classifyWithModelConfidence`: grammar-constrained `{"name":"…","confidence":N}`
    /// objects continuing the prompt's `{"tags":[{"name":"` runway, up to
    /// `maximumTags`, with the decline literal when enabled. Each tag carries the
    /// model's emitted digit AND the renormalized first-token softmax (captured at
    /// each name-start). Greedy so the digit is the model's argmax.
    private func structuredDecode(_ request: LLMClassificationRequest) async throws -> (tags: [LLMCalibrationTag], declined: Bool) {
        // Serial is simply a batch of one: the same item preparation and the same
        // lock-step generation loop as `classifyBatch`, so the two paths cannot
        // drift (verified: the `batch` eval mode reports identical tags+confidence
        // serial vs batched, and identical outputs before/after this unification).
        guard let item = try makeParallelItem(index: 0, request: request) else { return ([], true) }
        return try decodeParallel([item])[0]
    }

    /// The name→confidence boilerplate of the structured decode.
    static var confidenceBoilerplate: String { ClassificationReplyFormat.current.nameToDigit }

    /// Never SAMPLE what the grammar forces (LATENCY-REFINEMENT Phase 2). Given the
    /// text generated so far, returns the span the grammar leaves no choice about —
    /// so the caller can feed it in the same decode step as the last sampled token
    /// instead of spending a ~40 ms generation round per forced token — and whether
    /// the reply is already complete (tag cap reached, or an unambiguous decline),
    /// so no round is spent sampling end-of-text. The prompt and every real choice
    /// (each name token, each confidence digit, "another tag or stop") are untouched,
    /// so the decisions are the ones the plain decode would make.
    static func forcedContinuation(
        after generated: String,
        allowedTagNames: [String],
        allowDecline: Bool,
        maximumTags: Int
    ) -> (forced: String, finished: Bool) {
        // A quote inside a tag name would make the boilerplate ambiguous — don't force.
        guard !allowedTagNames.contains(where: { $0.contains("\"") }) else { return ("", false) }
        let chunks = generated.components(separatedBy: structuredSeparator)
        guard let current = chunks.last else { return ("", false) }

        if let boilerplate = current.range(of: confidenceBoilerplate) {
            let tail = current[boilerplate.upperBound...]
            guard let digit = tail.first else { return ("", false) }           // the digit is a real choice
            guard ("1"..."5").contains(String(digit)) else { return ("", false) }
            let afterDigit = String(tail.dropFirst())
            if afterDigit.isEmpty {
                // Item complete: at the cap nothing but end-of-text can follow.
                return ("", chunks.count >= max(1, maximumTags))
            }
            // The model chose to continue: the rest of `},{"name":"` is forced.
            if structuredSeparator.hasPrefix(afterDigit) {
                return (String(structuredSeparator.dropFirst(afterDigit.count)), false)
            }
            return ("", false)
        }

        // Still inside a name (or its trailing boilerplate).
        if chunks.count == 1, allowDecline, current == declineLiteral,
           !allowedTagNames.contains(where: { $0.hasPrefix(declineLiteral) }) {
            return ("", true)
        }
        for name in allowedTagNames where !name.isEmpty && current.hasPrefix(name) {
            let tail = String(current.dropFirst(name.count))
            guard confidenceBoilerplate.hasPrefix(tail) else { continue }
            // `name` is complete only if no longer tag name could still be forming.
            if tail.isEmpty, allowedTagNames.contains(where: { $0 != name && $0.hasPrefix(name) }) { continue }
            return (String(confidenceBoilerplate.dropFirst(tail.count)), false)
        }
        return ("", false)
    }

    /// `VAULT_NO_FORCED_SPANS=1` restores sample-everything decoding (for A/B evals).
    private static let feedsForcedSpans = ProcessInfo.processInfo.environment["VAULT_NO_FORCED_SPANS"] != "1"

    /// The inter-object boilerplate of the structured decode (`},{"name":"`): a
    /// name begins at step 0 and right after this completes.
    static var structuredSeparator: String { ClassificationReplyFormat.current.itemSeparator }

    /// Turns one sequence's generated `Name","confidence":N},{"name":"…` text into
    /// tags (shared by the serial and the batched decode).
    static func parseStructuredOutput(
        _ generated: String,
        nameStartProbabilities: [Double],
        allowedTagNames: [String],
        thresholds effectiveThresholds: [Double]
    ) -> (tags: [LLMCalibrationTag], declined: Bool) {
        if generated.trimmingCharacters(in: .whitespacesAndNewlines) == Self.declineLiteral {
            return ([], true)
        }
        // Each object continuation is `Name","confidence":N`; split on the
        // inter-object separator, then on the name→confidence boilerplate. Keep
        // only real taxonomy names, de-duplicated (first occurrence wins).
        let chunks = generated.components(separatedBy: structuredSeparator)
        var tags: [LLMCalibrationTag] = []
        var seen = Set<String>()
        for (index, chunk) in chunks.enumerated() {
            guard let range = chunk.range(of: confidenceBoilerplate) else { continue }
            let name = String(chunk[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedTagNames.contains(name), seen.insert(name).inserted else { continue }
            let digit = chunk[range.upperBound...].first.flatMap { Int(String($0)) } ?? 0
            let probability = index < nameStartProbabilities.count ? nameStartProbabilities[index] : 0
            tags.append(LLMCalibrationTag(
                name: name,
                modelConfidence: min(5, max(1, digit)),
                softmaxConfidence: Self.confidence(fromProbability: probability, thresholds: effectiveThresholds),
                softmaxProbability: probability
            ))
        }
        return (tags, tags.isEmpty)
    }

    /// Truncate the KV cache to the longest common prefix with `tokens`, drop the
    /// rest, and prefill the remaining suffix in chunks (always leaving ≥1 token
    /// to decode). Mirrors the reuse logic inlined in `classify`; factored out for
    /// the calibration decode so the hot path stays byte-for-byte unchanged.
    private func prefillReusingCache(_ tokens: [llama_token], errorLabel: String) throws {
        var common = 0
        while common < min(tokens.count, cachedTokens.count), tokens[common] == cachedTokens[common] {
            common += 1
        }
        if common == tokens.count { common = max(0, common - 1) }
        llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(common), -1)
        cachedTokens = Array(tokens.prefix(common))
        var index = common
        while index < tokens.count {
            let end = min(index + 512, tokens.count)
            var chunk = Array(tokens[index..<end])
            let status = chunk.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            guard status == 0 else {
                cachedTokens = []
                llama_memory_seq_rm(llama_get_memory(context), 0, 0, -1)
                throw OnDeviceLLMError.inference("\(errorLabel) (\(status))")
            }
            cachedTokens.append(contentsOf: tokens[index..<end])
            index = end
        }
    }

    /// A separate tiny constrained decode used only after the name grammar
    /// returned `none`. It copies one salient named noun phrase from the local
    /// title/summary; the common classification loop above is untouched.
    public func extractResearchSubject(
        _ request: LLMResearchSubjectRequest
    ) async throws -> ResearchSubject? {
        let summary = request.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = """
        Extract one short named entity or salient noun phrase that would be useful to research before classifying this video. Copy the phrase exactly from the title or summary. Prefer a creator handle, quoted show/game/work name, organization, person, or product. Return \"none\" if no such phrase exists. Return only one quoted phrase or none.

        Title: \(request.title)
        Summary: \(summary)
        Answer:
        """
        let tokens = try tokenize(prompt)
        guard tokens.count + 32 <= contextTokenLimit else {
            throw OnDeviceLLMError.inference("research-subject-prompt-exceeds-context (\(tokens.count) tokens)")
        }

        var common = 0
        while common < min(tokens.count, cachedTokens.count), tokens[common] == cachedTokens[common] {
            common += 1
        }
        if common == tokens.count { common = max(0, common - 1) }
        llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(common), -1)
        cachedTokens = Array(tokens.prefix(common))

        var index = common
        while index < tokens.count {
            let end = min(index + 512, tokens.count)
            var chunk = Array(tokens[index..<end])
            let status = chunk.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            guard status == 0 else {
                cachedTokens = []
                llama_memory_seq_rm(llama_get_memory(context), 0, 0, -1)
                throw OnDeviceLLMError.inference("research-subject-prompt-decode-failed (\(status))")
            }
            cachedTokens.append(contentsOf: tokens[index..<end])
            index = end
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_grammar(vocab, Self.researchSubjectGrammar, "root"))
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var generated = ""
        for _ in 0..<24 {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            generated += piece(for: token)
            var single = [token]
            let status = single.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, 1))
            }
            guard status == 0 else {
                cachedTokens = []
                llama_memory_seq_rm(llama_get_memory(context), 0, 0, -1)
                throw OnDeviceLLMError.inference("research-subject-generation-decode-failed (\(status))")
            }
            cachedTokens.append(token)
        }

        let value = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != Self.declineLiteral else { return nil }
        return ResearchSubject(kind: .term, subject: value)
    }

    /// Decode 2 (RESEARCH-REDESIGN §5, revised): after the classification decode,
    /// ask the model — over the SAME KV-cached evidence prefix — only which named
    /// subjects it does NOT recognize and would look up. Terms only: urgency is
    /// derived from the Decode-1 confidences (`ResearchUrgency`), because the live
    /// smoke showed model-emitted urgency just anchors to the prompt default.
    /// Grammar-constrained to `{"needs":["Term",…]}`; terms are copied spans.
    /// Empty in steady state (a recognized video yields `[]`).
    public func researchNeeds(_ request: LLMResearchNeedsRequest) async throws -> [String] {
        let maximumTerms = max(1, request.maximumTerms)
        let grammar = Self.researchNeedsGrammar(maximumTerms: maximumTerms)
        // The ask + the JSON runway (prefilled, never generated). The evidence
        // above is reused from Decode 1's KV.
        let researchAsk = """
        Now, over the SAME video, list up to \(maximumTerms) named subjects in the evidence above that you do NOT recognize and would look up before trusting the tags — a specific person, creator, work, game, show, organization, product, place, or event whose meaning you are genuinely unsure of. Copy each term exactly from the evidence. Do not list anything you already recognize; if you recognize everything, return an empty list. Reply with one JSON object only, no prose.
        Research JSON: {"needs":[
        """
        let prompt = request.staticPrefix + "\n\n" + request.dynamicSuffix + "\n\n" + researchAsk
        let tokens = try tokenize(prompt)
        guard tokens.count + 32 <= contextTokenLimit else {
            throw OnDeviceLLMError.inference("research-needs-prompt-exceeds-context (\(tokens.count) tokens)")
        }
        try prefillReusingCache(tokens, errorLabel: "research-needs-prompt-decode-failed")

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_grammar(vocab, grammar, "root"))
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        let decodeCap = min(max(1, contextTokenLimit - tokens.count - 1), maximumTerms * 24 + 16)
        var generated = ""
        for _ in 0..<decodeCap {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            generated += piece(for: token)
            var single = [token]
            let status = single.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, 1))
            }
            guard status == 0 else {
                cachedTokens = []
                llama_memory_seq_rm(llama_get_memory(context), 0, 0, -1)
                throw OnDeviceLLMError.inference("research-needs-generation-decode-failed (\(status))")
            }
            cachedTokens.append(token)
        }
        return Self.parseResearchTerms(generated)
    }

    static let researchTermEdgeJunk: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.formUnion(.punctuationCharacters)
        set.formUnion(.symbols)
        set.remove(charactersIn: "@")
        return set
    }()

    /// Extract the quoted term spans out of Decode 2's generated `"A","B"]}` text
    /// (the grammar guarantees the quoting). Robust to the empty-list case (`]}`
    /// immediately → no quoted spans). De-duplicates, keeping order.
    static func parseResearchTerms(_ generated: String) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        var rest = Substring(generated)
        while let open = rest.range(of: "\"") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "\"") else { break }
            // The open-vocabulary span can pick up stray edge punctuation from the
            // title (live smoke: `:皇室戰爭` from `【皇室戰爭】`-style brackets) — trim it
            // so the researched subject is the entity itself. `@` is kept (handles).
            let term = String(afterOpen[..<close.lowerBound])
                .trimmingCharacters(in: Self.researchTermEdgeJunk)
            if !term.isEmpty, seen.insert(term).inserted { terms.append(term) }
            rest = afterOpen[close.upperBound...]
        }
        return terms
    }

    // MARK: - Diagnostic free-text generation (eval only)

    /// Greedy, ungrammared generation with a mild repetition penalty. NOT a
    /// production path: the correction-summary feature that used free text was
    /// removed (5ca3ff7) after a small model fabricated rules that poisoned
    /// classification. This exists solely so `VaultClassifierEval summarize` can
    /// re-measure that behaviour on synthetic corrections before anyone considers
    /// bringing it back. Stops at end-of-text, `maximumTokens`, or any stop string.
    /// `chat: true` wraps the prompt as a single user turn in the model's own chat
    /// template (how an instruct model is meant to be asked); `false` is a raw
    /// completion, which is how the removed feature actually called it.
    public func generateTextForEvaluation(prompt rawPrompt: String, maximumTokens: Int = 240, stop: [String] = ["\n\n\n"], chat: Bool = false) throws -> String {
        let prompt = chat ? try chatFormatted(user: rawPrompt) : rawPrompt
        let tokens = try tokenize(prompt, addSpecial: !chat)
        guard tokens.count + maximumTokens + 8 <= contextTokenLimit else {
            throw OnDeviceLLMError.inference("eval-prompt-exceeds-context (\(tokens.count) tokens)")
        }
        try prefillReusingCache(tokens, errorLabel: "eval-prompt-decode-failed")
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1, 0, 0))
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        var generated = ""
        generation: for _ in 0..<maximumTokens {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            generated += piece(for: token)
            for marker in stop where generated.hasSuffix(marker) {
                generated.removeLast(marker.count)
                break generation
            }
            var single = [token]
            let status = single.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, 1))
            }
            guard status == 0 else {
                cachedTokens = []
                llama_memory_seq_rm(llama_get_memory(context), 0, 0, -1)
                throw OnDeviceLLMError.inference("eval-generation-decode-failed (\(status))")
            }
            cachedTokens.append(token)
        }
        return generated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chatFormatted(user: String) throws -> String {
        let template = llama_model_chat_template(model, nil)   // nil → llama.cpp falls back to chatml
        return try user.withCString { content -> String in
            try "user".withCString { role -> String in
                var message = llama_chat_message(role: role, content: content)
                var buffer = [CChar](repeating: 0, count: user.utf8.count * 2 + 1_024)
                let written = llama_chat_apply_template(template, &message, 1, true, &buffer, Int32(buffer.count))
                guard written > 0, Int(written) <= buffer.count else {
                    throw OnDeviceLLMError.inference("eval-chat-template-failed (\(written))")
                }
                return String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
    }

    // MARK: - Contract pieces

    /// The reserved decline literal: without it the grammar would FORCE a tag
    /// onto every video (grotesquely visible with a one-tag taxonomy), and
    /// renormalized confidence would degenerate to certainty. If the taxonomy
    /// legitimately contains a tag with this exact name, that tag wins.
    static let declineLiteral = "none"

    /// Quoted non-newline text or `none`; `ResearchSubject` applies the final
    /// entity-only word/character bounds before anything can be queued.
    static let researchSubjectGrammar = #"""
    root ::= "none" | "\"" subject "\""
    subject ::= character+ (" " character+)*
    character ::= [^"\\\r\n\t ]
    """#

    /// Decode 2 grammar (RESEARCH-REDESIGN §5, revised). Continues the prompt's
    /// `{"needs":[` runway with either an empty list (`]}`) or a bounded chain of
    /// quoted terms (`"A","B"]}`). Terms only — urgency is derived, not emitted.
    /// The static term/char rules are a raw-string block (so GBNF's own
    /// backslash-quote literals need no double-escaping); only the bounded tail
    /// chain is built by interpolation. `term` is an open-vocabulary copied span
    /// (same char class as `researchSubjectGrammar`).
    static func researchNeedsGrammar(maximumTerms: Int) -> String {
        let bound = max(1, maximumTerms)
        let extra = bound - 1
        var lines: [String] = []
        let rootBody = extra > 0 ? "termobj tail0" : "termobj"
        // Empty list `]}`, or a bounded chain of quoted terms then `]}`.
        lines.append(#"root ::= "]}" | \#(rootBody) "]}""#)
        for i in 0..<extra {
            let continuation = i == extra - 1 ? "" : " tail\(i + 1)"
            lines.append(#"tail\#(i) ::= "" | "," termobj\#(continuation)"#)
        }
        lines.append(#"""
        termobj ::= "\"" term "\""
        term ::= termchar+ (" " termchar+)*
        termchar ::= [^"\\\r\n\t ]
        """#)
        return lines.joined(separator: "\n")
    }


    /// The production GBNF: each tag is a full object continuation
    /// `Name","confidence":N` so the model emits its OWN confidence digit — the
    /// structured Decode 1 of RESEARCH-REDESIGN §5. Continues the same prompt
    /// runway (`{"tags":[{"name":"`); the inter-object separator is `},{"name":"`.
    /// Diagnostic-only (calibration eval); returns nil when no name is usable.
    static func namesWithConfidenceGrammar(allowed: [String], allowDecline: Bool = true, maximumTags: Int = 1, minimumTags: Int = 0) -> String? {
        let literals = allowed
            .filter { !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }
            .map { name in
                "\"" + name
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
        guard !literals.isEmpty else { return nil }
        let bound = max(1, maximumTags)
        // At least `mandatory` items are forced (no "" alternative); the remaining
        // `optional` items are the bounded tail chain, so the model emits between
        // max(1,min) and max items. Decline is only offered when min == 0.
        let minimum = min(bound, max(0, minimumTags))
        let mandatory = max(1, minimum)
        let optional = bound - mandatory
        var lines: [String] = []
        // The mandatory objects are inlined as `obj osep obj osep …`.
        var rootBody = (0..<mandatory).map { $0 == 0 ? "obj" : "osep obj" }.joined(separator: " ")
        if optional > 0 { rootBody += " tail0" }
        if minimum == 0, allowDecline, !allowed.contains(declineLiteral) {
            lines.append("root ::= \"\(declineLiteral)\" | \(rootBody)")
        } else {
            lines.append("root ::= \(rootBody)")
        }
        for i in 0..<optional {
            let continuation = i == optional - 1 ? "" : " tail\(i + 1)"
            lines.append("tail\(i) ::= \"\" | osep obj\(continuation)")
        }
        lines.append("obj ::= name conf")
        // conf emits `","confidence":` then a single 1–5 digit.
        func literal(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        lines.append("conf ::= \(literal(confidenceBoilerplate)) digit")
        lines.append("digit ::= \"1\" | \"2\" | \"3\" | \"4\" | \"5\"")
        // osep is the boilerplate between two objects: `},{"name":"`.
        lines.append("osep ::= \(literal(structuredSeparator))")
        lines.append("name ::= " + literals.joined(separator: " | "))
        return lines.joined(separator: "\n")
    }

    /// Maps the first chosen token's renormalized softmax probability onto the
    /// discrete 1–5 scale via the configured ascending thresholds (2, 3, 4, 5).
    static func confidence(fromProbability p: Double, thresholds: [Double] = [0.20, 0.40, 0.60, 0.85]) -> Int {
        var level = 1
        for threshold in thresholds.sorted() where p >= threshold { level += 1 }
        return min(5, level)
    }

    // MARK: - llama.cpp plumbing

    private func tokenize(_ text: String, addSpecial: Bool = true) throws -> [llama_token] {
        let utf8 = Array(text.utf8)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
        let written = utf8.withUnsafeBufferPointer { buffer -> Int32 in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { chars in
                llama_tokenize(vocab, chars, Int32(buffer.count), &tokens, Int32(tokens.count), addSpecial, true)
            }
        }
        guard written >= 0 else { throw OnDeviceLLMError.inference("tokenization-failed") }
        return Array(tokens.prefix(Int(written)))
    }

    private func piece(for token: llama_token) -> String {
        var buffer = [CChar](repeating: 0, count: 192)
        let written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        guard written > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Softmax probability of `token` renormalized over `candidates` (the
    /// grammar-legal first moves), from the last decode's logits.
    private func probability(of token: llama_token, among candidates: Set<llama_token>, outputIndex: Int32 = -1) -> Double {
        guard let logits = llama_get_logits_ith(context, outputIndex) else { return 0 }
        let vocabularySize = Int(llama_vocab_n_tokens(vocab))
        let pool = candidates.union([token]).filter { Int($0) < vocabularySize && $0 >= 0 }
        guard !pool.isEmpty else { return 0 }
        let maximum = pool.map { logits[Int($0)] }.max() ?? 0
        var sum = 0.0
        for candidate in pool { sum += Double(exp(logits[Int(candidate)] - maximum)) }
        guard sum > 0 else { return 0 }
        return Double(exp(logits[Int(token)] - maximum)) / sum
    }

    // MARK: - Model discovery

    /// The directory scanned for user-provided model files.
    public nonisolated static func modelsDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(VaultRuntimeEnvironment.current.classifierSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// Every *.gguf available for the settings picker, sorted by name.
    public nonisolated static func availableModelFiles() -> [String] {
        availableModelFiles(in: modelsDirectory())
    }

    /// Directory-injected variant used by the model library and its tests.
    /// Catalog downloads and manually copied GGUF files intentionally share
    /// one picker inventory.
    public nonisolated static func availableModelFiles(in directory: URL?) -> [String] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
              ) else {
            return []
        }
        return entries
            .filter {
                guard $0.pathExtension.lowercased() == "gguf" else { return false }
                // Follow symlinks: a manually-symlinked model (e.g. into the
                // Hugging Face cache) resolves to a regular file and is valid.
                let resolved = $0.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// The model file to load. A configured file name wins; then the
    /// `ADAMANCIA_VAULT_LLM_MODEL` environment variable; then the first
    /// available file under `<app support>/<environment dir>/models/`.
    public nonisolated static func defaultModelPath(
        preferredFileName: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let preferredFileName, !preferredFileName.isEmpty, !preferredFileName.contains("/"),
           let directory = modelsDirectory() {
            let candidate = directory.appendingPathComponent(preferredFileName).path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        if let explicit = environment["ADAMANCIA_VAULT_LLM_MODEL"], !explicit.isEmpty {
            return FileManager.default.fileExists(atPath: explicit) ? explicit : nil
        }
        // No silent default: the user picks a model (the app suggests one for
        // their RAM, e.g. Qwen2.5-7B on a 16 GB Mac) and downloads it. Nothing is
        // bundled or auto-selected, so a fresh install classifies nothing until
        // the user chooses — never a surprise model.
        return nil
    }
}
