import Foundation
import VaultClassifierCore
import Cllama

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
public actor VaultLocalLLMEngine: OnDeviceLLM, OnDeviceResearchSubjectExtracting, OnDeviceCorrectionSummarizing {
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

    public func classify(_ request: LLMClassificationRequest) async throws -> LLMClassificationResult {
        let effectiveAllowDecline = request.allowDecline ?? configuration.allowDecline
        let effectiveThresholds = request.confidenceThresholds ?? configuration.confidenceThresholds
        guard let grammar = Self.nameGrammar(allowed: request.allowedTagNames, allowDecline: effectiveAllowDecline) else {
            // No usable tag names → definitively empty, matching the stub's shape.
            return LLMClassificationResult(tags: [], unknownTerms: [])
        }
        let prompt = request.staticPrefix + "\n\n" + request.dynamicSuffix
        let tokens = try tokenize(prompt)
        guard tokens.count + 24 <= contextTokenLimit else {
            throw OnDeviceLLMError.inference("prompt-exceeds-context (\(tokens.count) tokens)")
        }

        // Static-prefix reuse: keep the longest common prefix of the KV cache,
        // drop the rest, and prefill only what changed. Always leave at least
        // one token to decode so the call ends with fresh logits.
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
                throw OnDeviceLLMError.inference("prompt-decode-failed (\(status))")
            }
            cachedTokens.append(contentsOf: tokens[index..<end])
            index = end
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_grammar(vocab, grammar, "root"))
        if configuration.temperature > 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(configuration.temperature)))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(0xC1A5))
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        }

        // Confidence is measured among the legal first moves: the distinct
        // first tokens of the allowed names. Renormalizing over that set (not
        // the full vocabulary) is what separates "certain" from "guessing" —
        // full-vocabulary mass on structurally plausible but grammar-illegal
        // tokens would otherwise dilute every probability.
        let candidateNames = effectiveAllowDecline
            ? request.allowedTagNames + [Self.declineLiteral]
            : request.allowedTagNames
        let candidateFirstTokens = Set(candidateNames.compactMap { try? tokenize($0, addSpecial: false).first })

        var generated = ""
        var firstTokenProbability: Double?
        for step in 0..<configuration.maximumOutputTokens {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            if step == 0 { firstTokenProbability = probability(of: token, among: candidateFirstTokens) }
            generated += piece(for: token)
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

        let name = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.allowedTagNames.contains(name) else {
            // The decline literal (or, unreachable via grammar, any stray
            // output) resolves to a definitive empty classification.
            return LLMClassificationResult(tags: [], unknownTerms: [])
        }
        let confidence = Self.confidence(fromProbability: firstTokenProbability ?? 0, thresholds: effectiveThresholds)
        return LLMClassificationResult(tags: [LLMTagScore(name: name, confidence: confidence)], unknownTerms: [])
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

    /// Distills the user's own corrections into a short natural-language guidance
    /// block. Local-only free-text generation; returns "" if there is nothing to
    /// summarize (the caller then keeps the deterministic fallback).
    public func summarizeCorrections(_ request: LLMCorrectionSummaryRequest) async throws -> String {
        guard !request.items.isEmpty else { return "" }
        let allowed = request.allowedTagNames.prefix(40).joined(separator: ", ")
        let corrections = request.items.prefix(24).map { item -> String in
            let tags = item.tagNames.isEmpty ? "no tag" : item.tagNames.joined(separator: ", ")
            let note = (item.note?.isEmpty == false) ? " — note: \(item.note!)" : ""
            return "- \"\(item.title)\" -> \(tags)\(note)"
        }.joined(separator: "\n")
        let prompt = """
        You refine a video-tagging assistant's guidance from a user's past corrections. From the corrections below, write 2 to 5 short imperative rules that capture how this user wants videos tagged so future videos match. Be concise and specific, use only the allowed tags, and do not restate every example.

        Allowed tags: \(allowed)

        Corrections:
        \(corrections)

        Rules:
        """
        return try generateFreeText(prompt: prompt, maximumTokens: 200)
    }

    /// Free-form (ungrammared) greedy generation with a repetition penalty,
    /// reusing the same KV-cache prefix handling as the constrained decodes.
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

    /// GBNF grammar admitting exactly one of the allowed tag names, plus the
    /// decline literal when enabled. Names with embedded newlines cannot be
    /// expressed as a GBNF literal and are skipped.
    static func nameGrammar(allowed: [String], allowDecline: Bool = true) -> String? {
        var literals = allowed
            .filter { !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }
            .map { name in
                "\"" + name
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
        guard !literals.isEmpty else { return nil }
        if allowDecline, !allowed.contains(declineLiteral) {
            literals.append("\"\(declineLiteral)\"")
        }
        return "root ::= " + literals.joined(separator: " | ")
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
