import Foundation
import VaultClassifierCore
import VaultClassifierBridge
import VaultClassifierLLM

// The cloud-provider sub-app: profile CRUD, live connection tests, model-catalog probing and the persisted test/usage records. Research-grounding only — tagging never touches a provider.
// Split out of VaultClassifierApp.swift (CLASSIFIER-INDEPENDENCE §7, Phase 5):
// same type, same behaviour — pinned by ViewModelCharacterizationTests.
@MainActor
extension VaultClassifierViewModel {
    nonisolated static func researchCredential(
        for profile: APIKeyProviderProfile
    ) throws -> ProviderCredentialRecord {
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard !descriptor.credentialFields.isEmpty else { return .init(values: [:]) }
        let value = profile.credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard descriptor.credentialFields.count == 1,
              let field = descriptor.credentialFields.first,
              !value.isEmpty else {
            throw ProviderTestProtocolError.missingCredential
        }
        let credential = ProviderCredentialRecord(values: [field: value])
        try credential.validate(for: descriptor)
        return credential
    }

    func llmProviderProfileIDs() -> Set<String> {
        Set(localState?.workspaceCatalog.providerProfiles.compactMap { profile in
            profile.type.supportsLLMConfiguration ? profile.id : nil
        } ?? [])
    }

    func reconcileProviderModelCatalogs() {
        let allowedProfileIDs = llmProviderProfileIDs()
        let retainedCatalogs = providerModelCatalogs.filter { allowedProfileIDs.contains($0.key) }
        guard retainedCatalogs != providerModelCatalogs else { return }
        providerModelCatalogs = retainedCatalogs
        providerModelCatalogStore?.save(retainedCatalogs, allowedProfileIDs: allowedProfileIDs)
    }

    func persistProviderModelCatalogs() {
        providerModelCatalogStore?.save(providerModelCatalogs, allowedProfileIDs: llmProviderProfileIDs())
    }

    func createProviderProfile(typeRaw: String) {
        do {
            guard let type = APIKeyProviderType(rawValue: typeRaw),
                  var catalog = localState?.workspaceCatalog else {
                throw WebBridgeInputError.invalidChoice("provider type")
            }
            let profile = APIKeyProviderProfile(type: type)
            catalog.providerProfiles.append(profile)
            try coordinator?.updateWorkspaceCatalog(catalog)
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    /// A provider test is always an explicit user action. It sends either the
    /// fixed harmless language-model prompt or a bounded provider-specific
    /// platform health request or fixed raw-search query, never browser
    /// evidence or catalog data, and records no credential or headers.
    func testProviderProfile(
        profileID: String,
        rawCredential: String? = nil,
        customEndpoint: String? = nil,
        testModelIdentifier: String? = nil,
        protocolConfiguration: [String: String]? = nil
    ) {
        guard !testingProviderProfileIDs.contains(profileID) else { return }
        successfulProviderTestProfileIDs.remove(profileID)
        let profile: APIKeyProviderProfile
        do {
            profile = try applyProviderConnection(
                profileID: profileID,
                rawCredential: rawCredential,
                customEndpoint: customEndpoint,
                testModelIdentifier: testModelIdentifier,
                protocolConfiguration: protocolConfiguration
            )
        } catch {
            issue = error.localizedDescription
            return
        }
        testingProviderProfileIDs.insert(profileID)
        issue = nil
        Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var prepared: ProviderTestPreparedRequest?
            do {
                let credential = try self.providerCredential(for: profileID)
                let request = try ProviderTestProtocol.prepare(profile: profile)
                prepared = request
                var urlRequest = URLRequest(url: request.plan.url)
                urlRequest.httpMethod = request.plan.method
                urlRequest.httpBody = request.body.isEmpty ? nil : request.body
                urlRequest.timeoutInterval = 30
                request.plan.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
                try self.apply(credential: credential, to: &urlRequest, plan: request.plan)
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                guard let http = response as? HTTPURLResponse else { throw ProviderTestProtocolError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw ProviderTestHTTPError.status(http.statusCode) }
                let responseUsage = (try? ProviderTestProtocol.usage(
                    from: data,
                    format: request.plan.bodyFormat
                )) ?? .init(tokenCount: nil)
                let parsed: ProviderTestParsedResponse
                do {
                    parsed = try ProviderTestProtocol.parseResponse(data, format: request.plan.bodyFormat, operation: request.operation)
                } catch {
                    throw ProviderResponseParseFailure(
                        underlyingError: error,
                        statusCode: http.statusCode,
                        responseShape: ProviderTestProtocol.responseShape(for: data),
                        usage: responseUsage
                    )
                }
                try self.appendProviderTestRecord(.init(
                    profileID: profile.id,
                    provider: profile.type.rawValue,
                    model: ProviderTestProtocol.modelIdentifier(for: profile),
                    operation: request.operation.rawValue,
                    endpoint: ProviderTestProtocol.safeEndpoint(request.plan.url),
                    method: request.plan.method,
                    statusCode: http.statusCode,
                    durationMilliseconds: duration,
                    tokenCount: parsed.usage.tokenCount,
                    outcome: "succeeded"
                ))
                self.successfulProviderTestProfileIDs.insert(profileID)
                self.issue = nil
            } catch {
                let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                if let prepared {
                    let failure = self.providerFailureMetadata(for: error)
                    try? self.appendProviderTestRecord(.init(
                        profileID: profile.id,
                        provider: profile.type.rawValue,
                        model: ProviderTestProtocol.modelIdentifier(for: profile),
                        operation: prepared.operation.rawValue,
                        endpoint: ProviderTestProtocol.safeEndpoint(prepared.plan.url),
                        method: prepared.plan.method,
                        statusCode: failure.statusCode,
                        responseShape: failure.responseShape,
                        durationMilliseconds: duration,
                        tokenCount: failure.tokenCount,
                        outcome: "failed"
                    ))
                }
                self.successfulProviderTestProfileIDs.remove(profileID)
                self.issue = error.localizedDescription
            }
            self.testingProviderProfileIDs.remove(profileID)
            self.onWebStateChange?()
        }
    }

    /// A Probe explicitly refreshes one locally cached provider model list. A
    /// failed refresh deliberately preserves the last successful bounded list
    /// until a later successful Probe replaces it.
    func fetchProviderModelCatalog(profileID: String) {
        guard !loadingProviderModelProfileIDs.contains(profileID) else { return }
        do {
            guard let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }) else {
                throw WebBridgeInputError.invalidChoice("provider profile")
            }
            let plan = try ProviderModelCatalogProtocol.prepare(profile: profile)
            loadingProviderModelProfileIDs.insert(profileID)
            providerModelCatalogErrors.removeValue(forKey: profileID)
            issue = nil
            Task { [weak self] in
                guard let self else { return }
                do {
                    let credential = plan.requiredCredentialFields.isEmpty
                        ? .init(values: [:])
                        : try self.providerCredential(for: profileID)
                    let response = try await self.performProviderRequest(plan: plan, body: nil, credential: credential, timeout: 30)
                    var models = try ProviderModelCatalogProtocol.parse(response.data, providerType: profile.type)
                    if profile.type == .ollama {
                        models = await self.ollamaModelsWithCapabilities(
                            models,
                            profile: profile,
                            credential: credential
                        )
                    }
                    self.providerModelCatalogs[profileID] = models
                    self.persistProviderModelCatalogs()
                    self.issue = nil
                } catch {
                    self.providerModelCatalogErrors[profileID] = error.localizedDescription
                }
                self.loadingProviderModelProfileIDs.remove(profileID)
                self.onWebStateChange?()
            }
        } catch {
            providerModelCatalogErrors[profileID] = error.localizedDescription
            onWebStateChange?()
        }
    }

    func ollamaModelsWithCapabilities(
        _ models: [ProviderModelCatalogEntry],
        profile: APIKeyProviderProfile,
        credential: ProviderCredentialRecord
    ) async -> [ProviderModelCatalogEntry] {
        var resolved = [ProviderModelCatalogEntry]()
        for model in models {
            guard let request = try? ProviderModelCatalogProtocol.prepareOllamaToolCapabilityProbe(
                profile: profile,
                modelIdentifier: model.identifier
            ) else {
                resolved.append(model)
                continue
            }
            guard let response = try? await performProviderRequest(
                plan: request.plan,
                body: request.body,
                credential: credential,
                timeout: 5
            ) else {
                resolved.append(model)
                continue
            }
            var updated = model
            updated.supportsTools = ProviderModelCatalogProtocol.ollamaModelSupportsTools(response.data)
            resolved.append(updated)
        }
        return resolved
    }

    func probeProviderModelCatalog(profileID: String) {
        guard let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }),
              profile.type.supportsLLMConfiguration else {
            issue = WebBridgeInputError.invalidChoice("LLM provider profile").localizedDescription
            return
        }
        fetchProviderModelCatalog(profileID: profileID)
    }

    func providerCredential(for profileID: String) throws -> ProviderCredentialRecord {
        guard let profile = localState?.workspaceCatalog.providerProfiles.first(where: { $0.id == profileID }) else {
            throw ProviderTestProtocolError.missingCredential
        }
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        guard !descriptor.credentialFields.isEmpty else { return .init(values: [:]) }
        let normalizedCredential = profile.credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard descriptor.credentialFields.count == 1,
              let field = descriptor.credentialFields.first,
              !normalizedCredential.isEmpty else {
            throw ProviderTestProtocolError.missingCredential
        }
        let value = normalizedCredential
        let credential = ProviderCredentialRecord(values: [field: value])
        try credential.validate(for: descriptor)
        return credential
    }

    func providerFailureMetadata(
        for error: Error
    ) -> (statusCode: Int?, responseShape: String?, tokenCount: Int?) {
        if case let ProviderTestHTTPError.status(statusCode) = error {
            return (statusCode, nil, nil)
        }
        guard let failure = error as? ProviderResponseParseFailure else { return (nil, nil, nil) }
        return (failure.statusCode, failure.responseShape, failure.usage.tokenCount)
    }

    /// Sends a bounded provider request used by explicit connection tests and
    /// model-catalog probes.
    func performProviderRequest(
        plan: ProviderRequestPlan,
        body: Data?,
        credential: ProviderCredentialRecord,
        timeout: TimeInterval
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: plan.url)
        request.httpMethod = plan.method
        request.httpBody = body
        request.timeoutInterval = timeout
        plan.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try apply(credential: credential, to: &request, plan: plan)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderTestProtocolError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ProviderTestHTTPError.status(http.statusCode) }
        return (data, http)
    }

    func appendProviderTestRecord(_ record: ProviderRequestRecord) throws {
        guard var catalog = localState?.workspaceCatalog else { return }
        catalog.providerRequestRecords.insert(record, at: 0)
        // Keep every current-day classified request with known aggregate usage,
        // including a malformed 2xx response, so pruning cannot bypass the
        // configured daily budget.
        let todayStartMilliseconds = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1_000)
        let budgetRecords = catalog.providerRequestRecords.filter {
            $0.classifierTypeID != nil &&
                $0.tokenCount != nil &&
                $0.createdAtMilliseconds >= todayStartMilliseconds
        }
        let budgetRecordIDs = Set(budgetRecords.map(\.id))
        let otherRecords = catalog.providerRequestRecords.filter { !budgetRecordIDs.contains($0.id) }
        catalog.providerRequestRecords = budgetRecords + Array(otherRecords.prefix(100))
        let isLanguageModel = APIKeyProviderType(rawValue: record.provider)
            .map { ProviderProtocolRegistry.descriptor(for: $0).supportsLLMConfiguration } ?? false
        if isLanguageModel, let tokenCount = record.tokenCount {
            catalog.tokenUsage.insert(.init(
                provider: record.provider,
                model: record.model,
                tokenCount: tokenCount,
                status: record.outcome
            ), at: 0)
            catalog.tokenUsage = Array(catalog.tokenUsage.prefix(200))
        }
        try coordinator?.updateWorkspaceCatalog(catalog)
        refreshLocalState()
    }

    /// Stores every compact provider connection field in the local workspace.
    /// API keys and tokens are ordinary visible text fields: an empty committed
    /// value clears the saved credential.
    func applyProviderConnection(
        profileID: String,
        rawCredential: String?,
        customEndpoint: String?,
        testModelIdentifier: String?,
        protocolConfiguration: [String: String]?
    ) throws -> APIKeyProviderProfile {
        guard var catalog = localState?.workspaceCatalog,
              let index = catalog.providerProfiles.firstIndex(where: { $0.id == profileID }) else {
            throw WebBridgeInputError.invalidChoice("provider profile")
        }
        var profile = catalog.providerProfiles[index]
        if let customEndpoint {
            let cleaned = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.customEndpoint = cleaned.isEmpty ? nil : cleaned
        }
        if let testModelIdentifier {
            let cleaned = testModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.testModelIdentifier = cleaned.isEmpty ? nil : cleaned
        }
        if let protocolConfiguration {
            profile.protocolConfiguration = protocolConfiguration
        }
        let descriptor = ProviderProtocolRegistry.descriptor(for: profile.type)
        if descriptor.credentialFields.isEmpty {
            profile.credential = nil
        } else if let rawCredential {
            let value = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                profile.credential = nil
            } else {
                guard descriptor.credentialFields.count == 1,
                      let field = descriptor.credentialFields.first else {
                    throw WebBridgeInputError.invalidChoice("provider credential")
                }
                let credential = ProviderCredentialRecord(values: [field: value])
                try credential.validate(for: descriptor)
                profile.credential = credential.values[field]
            }
        }
        try profile.validate()
        profile.updatedAtMilliseconds = WorkspaceCatalog.now()
        catalog.providerProfiles[index] = profile
        try coordinator?.updateWorkspaceCatalog(catalog)
        refreshLocalState()
        return profile
    }

    func updateProviderConnection(
        profileID: String,
        rawCredential: String? = nil,
        customEndpoint: String?,
        testModelIdentifier: String?,
        protocolConfiguration: [String: String]?
    ) {
        successfulProviderTestProfileIDs.remove(profileID)
        do {
            _ = try applyProviderConnection(
                profileID: profileID,
                rawCredential: rawCredential,
                customEndpoint: customEndpoint,
                testModelIdentifier: testModelIdentifier,
                protocolConfiguration: protocolConfiguration
            )
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func deleteProviderProfile(profileID: String) {
        do {
            guard var catalog = localState?.workspaceCatalog,
                  catalog.providerProfiles.contains(where: { $0.id == profileID }) else {
                throw WebBridgeInputError.invalidChoice("provider profile")
            }
            catalog.providerProfiles.removeAll(where: { $0.id == profileID })
            catalog.providerRequestRecords.removeAll(where: { $0.profileID == profileID })
            for index in catalog.classifierTypes.indices {
                guard let current = catalog.classifierTypes[index].researchOverrides else { continue }
                let updated = Self.researchSettings(current, removingProviderID: profileID)
                if updated != current {
                    catalog.classifierTypes[index].researchOverrides = updated
                    catalog.classifierTypes[index].updatedAtMilliseconds = WorkspaceCatalog.now()
                }
            }
            successfulProviderTestProfileIDs.remove(profileID)
            try coordinator?.updateWorkspaceCatalog(catalog)
            if let currentSettings = localState?.settings {
                let research = Self.researchSettings(
                    currentSettings.research,
                    removingProviderID: profileID
                )
                guard research != currentSettings.research else {
                    refreshLocalState()
                    issue = nil
                    return
                }
                try coordinator?.updateSettings(.init(
                    packageUpdateMode: currentSettings.packageUpdateMode,
                    localLLM: currentSettings.localLLM,
                    research: research
                ))
            }
            refreshLocalState()
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    func confirmProviderProfileDeletion(profileID: String) {
        guard localState?.workspaceCatalog.providerProfiles.contains(where: { $0.id == profileID }) == true else {
            issue = WebBridgeInputError.invalidChoice("provider profile").localizedDescription
            return
        }
        presentNativeConfirmation(
            title: "Delete provider profile?",
            message: "This removes the local API key or token and token-usage records. It cannot be undone.",
            confirmTitle: "Delete profile"
        ) { [weak self] in
            self?.deleteProviderProfile(profileID: profileID)
        }
    }

    func apply(credential: ProviderCredentialRecord, to request: inout URLRequest, plan: ProviderRequestPlan) throws {
        func value(_ preferred: ProviderCredentialField) throws -> String {
            guard let value = credential.values[preferred] ?? credential.values[.apiKey] ?? credential.values[.bearerToken] else {
                throw ProviderTestProtocolError.missingCredential
            }
            return value
        }
        switch plan.authentication {
        case .none:
            return
        case .bearerToken, .bearerTokenAndClientID:
            request.setValue("Bearer \(try value(.bearerToken))", forHTTPHeaderField: plan.authenticationHeader ?? "Authorization")
        case .apiKeyHeader:
            request.setValue(try value(.apiKey), forHTTPHeaderField: plan.authenticationHeader ?? "X-API-Key")
        case .apiKeyQuery:
            guard var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else { throw ProviderTestProtocolError.invalidResponse }
            components.queryItems = (components.queryItems ?? []) + [.init(name: plan.authenticationHeader ?? "key", value: try value(.apiKey))]
            request.url = components.url
        case .awsSignatureV4:
            throw ProviderTestProtocolError.unsupportedProvider
        }
    }
}
