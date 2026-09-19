import Foundation
import VaultClassifierCore

// Provider request EXECUTION: the concrete request plan built from a
// ProviderProtocolDescriptor and the descriptor-backed protocol that performs
// it. The descriptor model, registry and error vocabulary stay in Core (the
// persisted provider records validate against them).

public struct ProviderRequestPlan: Equatable, Sendable {
    public var url: URL
    public var method: String
    public var bodyFormat: ProviderRequestBodyFormat
    public var headers: [String: String]
    public var authentication: ProviderAuthenticationMethod
    public var authenticationHeader: String?
    public var requiredCredentialFields: [ProviderCredentialField]

    public init(
        url: URL,
        method: String,
        bodyFormat: ProviderRequestBodyFormat,
        headers: [String: String],
        authentication: ProviderAuthenticationMethod,
        authenticationHeader: String?,
        requiredCredentialFields: [ProviderCredentialField]
    ) {
        self.url = url
        self.method = method
        self.bodyFormat = bodyFormat
        self.headers = headers
        self.authentication = authentication
        self.authenticationHeader = authenticationHeader
        self.requiredCredentialFields = requiredCredentialFields
    }
}

/// Native modules implement this protocol to consume a profile's declared
/// request grammar. It has no network method: dispatch remains a separate,
/// explicit action with a user-approved payload and local credential.
public protocol ProviderRequestProtocol: Sendable {
    var descriptor: ProviderProtocolDescriptor { get }
    func requestPlan(
        for profile: APIKeyProviderProfile,
        operation: ProviderOperation,
        modelIdentifier: String?
    ) throws -> ProviderRequestPlan
}

public struct DescriptorBackedProviderProtocol: ProviderRequestProtocol {
    public let descriptor: ProviderProtocolDescriptor

    public init(descriptor: ProviderProtocolDescriptor) {
        self.descriptor = descriptor
    }

    public func requestPlan(
        for profile: APIKeyProviderProfile,
        operation: ProviderOperation,
        modelIdentifier: String? = nil
    ) throws -> ProviderRequestPlan {
        guard profile.type.rawValue == descriptor.identifier,
              let format = descriptor.requestFormats.first(where: { $0.operation == operation }) else {
            throw ProviderProtocolError.unsupportedOperation
        }
        try profile.validateForDispatch()
        let baseURL = profile.customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? descriptor.defaultBaseURL
        guard let baseURL else { throw ProviderProtocolError.missingEndpoint }
        let path = substitute(format.pathTemplate, profile: profile, modelIdentifier: modelIdentifier)
        let resolvedBaseURL = substitute(baseURL, profile: profile, modelIdentifier: modelIdentifier)
        guard let url = URL(string: resolvedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            throw ProviderProtocolError.invalidEndpoint
        }
        var headers = descriptor.staticHeaders
        if format.bodyFormat != .queryOnly { headers["Content-Type"] = "application/json" }
        return .init(
            url: url,
            method: format.method,
            bodyFormat: format.bodyFormat,
            headers: headers,
            authentication: descriptor.authentication,
            authenticationHeader: descriptor.authenticationHeader,
            requiredCredentialFields: descriptor.credentialFields
        )
    }

    private func substitute(_ template: String, profile: APIKeyProviderProfile, modelIdentifier: String?) -> String {
        let model = modelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? profile.type.defaultModelIdentifier
        var result = template.replacingOccurrences(of: "{model}", with: model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model)
        for (field, value) in profile.protocolConfiguration {
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
            result = result.replacingOccurrences(of: "{\(field)}", with: encoded)
        }
        return result
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
