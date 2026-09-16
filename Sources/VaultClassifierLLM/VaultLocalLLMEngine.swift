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
public actor VaultLocalLLMEngine: OnDeviceLLM, OnDeviceResearchSubjectExtracting {
    public nonisolated let modelVersion: String

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let contextTokenLimit: Int
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
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw EngineError.contextCreationFailed
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.contextTokenLimit = configuration.contextTokens
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

    /// The shared structured decode behind both `classify` and
    /// `classifyWithModelConfidence`: grammar-constrained `{"name":"…","confidence":N}`
    /// objects continuing the prompt's `{"tags":[{"name":"` runway, up to
    /// `maximumTags`, with the decline literal when enabled. Each tag carries the
    /// model's emitted digit AND the renormalized first-token softmax (captured at
    /// each name-start). Greedy so the digit is the model's argmax.
    private func structuredDecode(_ request: LLMClassificationRequest) async throws -> (tags: [LLMCalibrationTag], declined: Bool) {
        let effectiveAllowDecline = request.allowDecline ?? configuration.allowDecline
        let effectiveThresholds = request.confidenceThresholds ?? configuration.confidenceThresholds
        let maximumTags = max(1, request.maximumTags)
        guard let grammar = Self.namesWithConfidenceGrammar(allowed: request.allowedTagNames, allowDecline: effectiveAllowDecline, maximumTags: maximumTags) else {
            return ([], true)
        }
        let prompt = request.staticPrefix + "\n\n" + request.dynamicSuffix
        let tokens = try tokenize(prompt)
        guard tokens.count + 24 <= contextTokenLimit else {
            throw OnDeviceLLMError.inference("prompt-exceeds-context (\(tokens.count) tokens)")
        }
        try prefillReusingCache(tokens, errorLabel: "prompt-decode-failed")

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_grammar(vocab, grammar, "root"))
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        let candidateNames = effectiveAllowDecline
            ? request.allowedTagNames + [Self.declineLiteral]
            : request.allowedTagNames
        let candidateFirstTokens = Set(candidateNames.compactMap { try? tokenize($0, addSpecial: false).first })

        // Between two `{"name":"…","confidence":N}` objects the scaffold emits
        // `},{"name":"` (no leading quote — the name's closing quote was consumed
        // by the confidence clause). A name begins at step 0 and right after this
        // separator completes, exactly where the first-token softmax is measured.
        let separatorText = "},{\"name\":\""
        let decodeCap = min(
            max(1, contextTokenLimit - tokens.count - 1),
            max(configuration.maximumOutputTokens, maximumTags * 24 + 8)
        )
        var generated = ""
        var nameStartProbabilities: [Double] = []
        var awaitingNameStart = true
        for _ in 0..<decodeCap {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            if awaitingNameStart {
                nameStartProbabilities.append(probability(of: token, among: candidateFirstTokens))
                awaitingNameStart = false
            }
            generated += piece(for: token)
            if generated.hasSuffix(separatorText) { awaitingNameStart = true }
            var single = [token]
            let status = single.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, 1))
            }
            guard status == 0 else {
                cachedTokens = []
                llama_memory_seq_rm(llama_get_memory(context), 0, 0, -1)
                throw OnDeviceLLMError.inference("generation-decode-failed (\(status))")
            }
            cachedTokens.append(token)
        }

        if generated.trimmingCharacters(in: .whitespacesAndNewlines) == Self.declineLiteral {
            return ([], true)
        }
        // Each object continuation is `Name","confidence":N`; split on the
        // inter-object separator, then on the name→confidence boilerplate. Keep
        // only real taxonomy names, de-duplicated (first occurrence wins).
        let confidenceBoilerplate = "\",\"confidence\":"
        let chunks = generated.components(separatedBy: separatorText)
        var tags: [LLMCalibrationTag] = []
        var seen = Set<String>()
        for (index, chunk) in chunks.enumerated() {
            guard let range = chunk.range(of: confidenceBoilerplate) else { continue }
            let name = String(chunk[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard request.allowedTagNames.contains(name), seen.insert(name).inserted else { continue }
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

    /// Free-form (ungrammared) greedy generation with a repetition penalty,
    /// reusing the same KV-cache prefix handling as the constrained decodes.
    /// Currently unused: the correction "summary" path that generalized sparse
    /// corrections into free-text rules was removed (a small model fabricated
    /// spurious rules that poisoned classification). Retained for a possible
    /// future grounded free-text need; delete if none materializes.
    private func generateFreeText(prompt: String, maximumTokens: Int) throws -> String {
        let tokens = try tokenize(prompt)
        guard tokens.count + maximumTokens <= contextTokenLimit else {
            throw OnDeviceLLMError.inference("summary-prompt-exceeds-context (\(tokens.count) tokens)")
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
                throw OnDeviceLLMError.inference("summary-prompt-decode-failed (\(status))")
            }
            cachedTokens.append(contentsOf: tokens[index..<end])
            index = end
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.15, 0, 0))
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var generated = ""
        for _ in 0..<maximumTokens {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            generated += piece(for: token)
            if generated.contains("\n\n\n") { break }
            var single = [token]
            let status = single.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, 1))
            }
            guard status == 0 else {
                cachedTokens = []
                llama_memory_seq_rm(llama_get_memory(context), 0, 0, -1)
                throw OnDeviceLLMError.inference("summary-generation-decode-failed (\(status))")
            }
            cachedTokens.append(token)
        }
        return generated.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// GBNF grammar admitting up to `maximumTags` of the allowed tag names,
    /// separated by the JSON scaffold's own `"},{"name":"` boilerplate — so the
    /// generated output stays a coherent continuation of the prompt's
    /// `{"tags":[{"name":"` runway (removing that scaffold measurably regressed
    /// accuracy) — plus the decline literal `none` when enabled. Names with
    /// embedded newlines cannot be expressed as a GBNF literal and are skipped;
    /// returns nil when no tag name is usable.
    static func namesGrammar(allowed: [String], allowDecline: Bool = true, maximumTags: Int = 1) -> String? {
        let literals = allowed
            .filter { !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }
            .map { name in
                "\"" + name
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
        guard !literals.isEmpty else { return nil }
        let bound = max(1, maximumTags)
        let extra = bound - 1  // optional additional names after the first
        var lines: [String] = []
        let rootBody = extra > 0 ? "name tail0" : "name"
        if allowDecline, !allowed.contains(declineLiteral) {
            lines.append("root ::= \"\(declineLiteral)\" | \(rootBody)")
        } else {
            lines.append("root ::= \(rootBody)")
        }
        // A bounded optional chain: each tail may end the list or add one more
        // `sep name`, so the model emits between 1 and `bound` names.
        for i in 0..<extra {
            let continuation = i == extra - 1 ? "" : " tail\(i + 1)"
            lines.append("tail\(i) ::= \"\" | sep name\(continuation)")
        }
        // The separator is the JSON boilerplate between two {"name":"…"} objects.
        lines.append("sep ::= \"\\\"},{\\\"name\\\":\\\"\"")
        lines.append("name ::= " + literals.joined(separator: " | "))
        return lines.joined(separator: "\n")
    }

    /// Like `namesGrammar`, but each tag is a full object continuation
    /// `Name","confidence":N` so the model emits its OWN confidence digit — the
    /// structured Decode 1 of RESEARCH-REDESIGN §5. Continues the same prompt
    /// runway (`{"tags":[{"name":"`); the inter-object separator is `},{"name":"`.
    /// Diagnostic-only (calibration eval); returns nil when no name is usable.
    static func namesWithConfidenceGrammar(allowed: [String], allowDecline: Bool = true, maximumTags: Int = 1) -> String? {
        let literals = allowed
            .filter { !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }
            .map { name in
                "\"" + name
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
        guard !literals.isEmpty else { return nil }
        let bound = max(1, maximumTags)
        let extra = bound - 1
        var lines: [String] = []
        let rootBody = extra > 0 ? "obj tail0" : "obj"
        if allowDecline, !allowed.contains(declineLiteral) {
            lines.append("root ::= \"\(declineLiteral)\" | \(rootBody)")
        } else {
            lines.append("root ::= \(rootBody)")
        }
        for i in 0..<extra {
            let continuation = i == extra - 1 ? "" : " tail\(i + 1)"
            lines.append("tail\(i) ::= \"\" | osep obj\(continuation)")
        }
        lines.append("obj ::= name conf")
        // conf emits `","confidence":` then a single 1–5 digit.
        lines.append("conf ::= \"\\\",\\\"confidence\\\":\" digit")
        lines.append("digit ::= \"1\" | \"2\" | \"3\" | \"4\" | \"5\"")
        // osep is the boilerplate between two objects: `},{"name":"`.
        lines.append("osep ::= \"},{\\\"name\\\":\\\"\"")
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
    private func probability(of token: llama_token, among candidates: Set<llama_token>) -> Double {
        guard let logits = llama_get_logits_ith(context, -1) else { return 0 }
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
