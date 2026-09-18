import Foundation
import VaultClassifierCore
import VaultClassifierResearch

// Live smoke test for provider-native search grounding. Performs ONE real
// grounded-generate against the configured provider (default Gemini
// google_search) through the same GroundedResearchExecutor / URLSession path
// the app uses, and prints the grounded description plus source URLs.
//
// The API key is read from the environment so it never appears on the command
// line, in this process's arguments, or anywhere this tool logs it.
//
// Usage:
//   GEMINI_API_KEY=<key> swift run VaultGroundingSmoke "HermitCraft" creator
//   GEMINI_API_KEY=<key> swift run VaultGroundingSmoke "HermitCraft" term gemini-2.0-flash
//
// Only the sanitized subject is sent to the provider — the same data-minimized
// contract as the in-app research loop.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

let env = ProcessInfo.processInfo.environment
let args = Array(CommandLine.arguments.dropFirst())

// Resolve the Gemini key without ever printing it. Prefer GEMINI_API_KEY from
// the environment; otherwise read the Gemini provider the user already saved in
// the app's own local state (the same on-device store the app uses). The raw
// key value is never logged — only its source is reported.
func resolveGeminiKey() -> (key: String, source: String)? {
    if let envKey = env["GEMINI_API_KEY"],
       !envKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return (envKey, "environment")
    }
    guard let directory = try? VaultRuntimeEnvironment.current.classifierSupportDirectoryURL() else {
        return nil
    }
    let stateURL = directory.appendingPathComponent("state.json", isDirectory: false)
    guard let state = try? LocalStateFile(url: stateURL).load() else { return nil }
    guard let profile = state.workspaceCatalog.providerProfiles.first(where: {
        $0.type == .gemini && !($0.credential ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }), let credential = profile.credential else {
        return nil
    }
    return (credential, "app state provider \"\(profile.name)\"")
}

guard let resolved = resolveGeminiKey() else {
    fail("error: no Gemini key found — set GEMINI_API_KEY, or save a Gemini provider in the app first.", code: 2)
}
let apiKey = resolved.key
print("• using Gemini key from: \(resolved.source)")

let rawSubject = args.first ?? "HermitCraft"
let kind: KnowledgeEntryKind = (args.count > 1 && args[1].lowercased() == "creator") ? .creator : .term
let model = args.count > 2 ? args[2] : (env["GEMINI_MODEL"] ?? APIKeyProviderType.gemini.defaultModelIdentifier)

guard let subject = ResearchSubject(kind: kind, subject: rawSubject) else {
    fail("error: subject failed sanitization for kind \(kind.rawValue): \(rawSubject)", code: 2)
}

let profile = APIKeyProviderProfile(type: .gemini, credential: apiKey)
guard GroundedGenerationProtocol.supportsProviderGrounding(profile: profile) else {
    fail("error: gemini does not report provider-grounding support in this build.", code: 2)
}

let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
let credential: ProviderCredentialRecord = descriptor.credentialFields.first
    .map { ProviderCredentialRecord(values: [$0: apiKey]) } ?? ProviderCredentialRecord(values: [:])

let configuration = GroundedResearchProviderConfiguration(
    llmProfile: profile,
    llmCredential: credential,
    llmModelIdentifier: model
)

print("→ grounding \(kind.rawValue) subject: \"\(subject.subject)\"  via Gemini google_search (model \(model))")
print("  (only this sanitized subject leaves the device)\n")

let http = URLSessionProviderHTTPClient()
let executor = GroundedResearchExecutor(http: http)

do {
    let result = try await executor.research(subject, using: configuration)
    print("✓ grounded description:\n\(result.knowledge.meaning)\n")
    print("sources (\(result.knowledge.sourceURLs.count)):")
    if result.knowledge.sourceURLs.isEmpty {
        print("  (none returned — the description is still stored)")
    } else {
        for url in result.knowledge.sourceURLs { print("  - \(url)") }
    }
    print("\ntokens charged: \(result.chargedTokenCount)")
    print("stored key:    \(result.knowledge.id)")
} catch {
    // Surface the provider's raw response so a failure is diagnosable
    // (e.g. rate-limit vs hard quota vs malformed request). send() drops the
    // body on non-2xx, so re-issue through a capturing transport.
    print("✗ grounding failed via executor: \(error)")
    final class Capture: @unchecked Sendable { var body = Data(); var status = 0 }
    let capture = Capture()
    let capturingHTTP = URLSessionProviderHTTPClient(transport: { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        capture.body = data
        capture.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, response)
    })
    if let request = try? GroundedGenerationProtocol.prepareGroundedGenerate(
        profile: profile, modelIdentifier: model, subject: subject.subject,
        kind: subject.kind, maximumOutputTokens: configuration.maximumOutputTokens
    ) {
        _ = try? await capturingHTTP.send(
            plan: request.plan, body: request.body, credential: credential, timeout: 30
        )
        print("\nHTTP \(capture.status) — raw response (first 1400 chars):")
        print(String(String(decoding: capture.body, as: UTF8.self).prefix(1400)))
    }
    exit(1)
}
