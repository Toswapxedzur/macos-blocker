import Foundation

/// The narrow HTTP seam used by background research. Request construction and
/// response parsing remain in the provider protocol types, while tests can
/// inject a transport that never reaches the network.
public protocol ProviderHTTPClient: Sendable {
    func send(
        plan: ProviderRequestPlan,
        body: Data?,
        credential: ProviderCredentialRecord,
        timeout: TimeInterval
    ) async throws -> (data: Data, response: HTTPURLResponse)
}

public struct URLSessionProviderHTTPClient: ProviderHTTPClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    public init(
        transport: @escaping Transport = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.transport = transport
    }

    public func send(
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

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderTestProtocolError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderTestHTTPError.status(http.statusCode)
        }
        return (data, http)
    }

    private func apply(
        credential: ProviderCredentialRecord,
        to request: inout URLRequest,
        plan: ProviderRequestPlan
    ) throws {
        func value(_ preferred: ProviderCredentialField) throws -> String {
            guard let value = credential.values[preferred]
                ?? credential.values[.apiKey]
                ?? credential.values[.bearerToken],
                ProviderCredentialRecord.isValid(value)
            else {
                throw ProviderTestProtocolError.missingCredential
            }
            return value
        }

        switch plan.authentication {
        case .none:
            return
        case .bearerToken, .bearerTokenAndClientID:
            request.setValue(
                "Bearer \(try value(.bearerToken))",
                forHTTPHeaderField: plan.authenticationHeader ?? "Authorization"
            )
        case .apiKeyHeader:
            request.setValue(
                try value(.apiKey),
                forHTTPHeaderField: plan.authenticationHeader ?? "X-API-Key"
            )
        case .apiKeyQuery:
            guard let requestURL = request.url,
                  var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
            else {
                throw ProviderTestProtocolError.invalidResponse
            }
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: plan.authenticationHeader ?? "key", value: try value(.apiKey))
            ]
            guard let authenticatedURL = components.url else {
                throw ProviderTestProtocolError.invalidResponse
            }
            request.url = authenticatedURL
        case .awsSignatureV4:
            throw ProviderTestProtocolError.unsupportedProvider
        }
    }
}

public enum ProviderTestHTTPError: Error, Equatable, LocalizedError, Sendable {
    case status(Int)

    public var errorDescription: String? {
        switch self {
        case .status(let status): return "The provider returned HTTP \(status)."
        }
    }
}
