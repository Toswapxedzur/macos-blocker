import Foundation

/// Resolves the public Vault service once for native clients. Development
/// launchers set `CB_PUBLIC_SERVER_URL` to the local website server; packaged
/// builds safely fall back to the public service. Only HTTPS is permitted away
/// from loopback so an environment typo cannot send requests to an arbitrary
/// cleartext host.
public struct VaultServiceEndpoint: Equatable, Sendable {
    public static let environmentKey = "CB_PUBLIC_SERVER_URL"
    public static let productionDefault = URL(string: "https://customblocker.com")!

    public let baseURL: URL

    public init(baseURL: URL) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              scheme == "https" || (scheme == "http" && Self.isLoopback(host)) else {
            throw VaultServiceEndpointError.invalidBaseURL
        }
        self.baseURL = baseURL
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        if let configured = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: configured),
           let endpoint = try? Self(baseURL: url) {
            return endpoint
        }
        // This literal has passed the same validation above and is intentionally
        // not user-configurable without the environment boundary.
        return try! Self(baseURL: productionDefault)
    }

    public func url(path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw VaultServiceEndpointError.invalidBaseURL
        }
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanPath.isEmpty,
              cleanPath.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw VaultServiceEndpointError.invalidPath
        }
        components.path = "/" + cleanPath
        guard let url = components.url else { throw VaultServiceEndpointError.invalidPath }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

public enum VaultServiceEndpointError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseURL
    case invalidPath

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "The Vault service endpoint must use HTTPS, except for an explicit loopback URL."
        case .invalidPath: return "The Vault service endpoint path is invalid."
        }
    }
}
