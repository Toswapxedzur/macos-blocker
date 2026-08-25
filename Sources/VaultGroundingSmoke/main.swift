import Foundation
import VaultClassifierCore

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

guard let apiKey = env["GEMINI_API_KEY"], !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    fail("error: set GEMINI_API_KEY in the environment (it is never read from argv).", code: 2)
}

let rawSubject = args.first ?? "HermitCraft"
let kind: KnowledgeEntryKind = (args.count > 1 && args[1].lowercased() == "creator") ? .creator : .term
let model = args.count > 2 ? args[2] : (env["GEMINI_MODEL"] ?? "gemini-2.0-flash")

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
    searchMode: .providerGrounding,
    llmProfile: profile,
    llmCredential: credential,
    llmModelIdentifier: model
)

print("→ grounding \(kind.rawValue) subject: \"\(subject.subject)\"  via Gemini google_search (model \(model))")
print("  (only this sanitized subject leaves the device)\n")

let executor = GroundedResearchExecutor(http: URLSessionProviderHTTPClient())

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
    fail("✗ grounding failed: \(error)", code: 1)
}
