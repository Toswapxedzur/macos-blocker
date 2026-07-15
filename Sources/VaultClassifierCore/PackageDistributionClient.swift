import Foundation

/// A deliberately small HTTP boundary for optional model-package distribution.
/// It has no account, browser, provider credential, scheduler, or activation
/// behavior. Tests can supply a local transport without opening a connection.
public protocol PackageDistributionHTTPTransport: Sendable {
    func perform(_ request: PackageDistributionHTTPRequest) async throws -> PackageDistributionHTTPResponse
}

public struct PackageDistributionHTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]

    public init(url: URL, method: String = "GET", headers: [String: String] = [:]) {
        self.url = url
        self.method = method
        self.headers = headers
    }
}

public struct PackageDistributionHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    /// The final URL observed by the transport. The client rejects a changed
    /// URL rather than silently accepting a redirect to another origin.
    public var responseURL: URL?

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = .init(), responseURL: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.responseURL = responseURL
    }
}

/// Production transport for the fixed data-only contract. It uses an ephemeral
/// session, disables HTTP redirect following, and leaves cache/retry policy to
/// the caller's local scheduling layer.
public struct URLSessionPackageDistributionHTTPTransport: PackageDistributionHTTPTransport {
    public init() {}

    public func perform(_ request: PackageDistributionHTTPRequest) async throws -> PackageDistributionHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 45
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: PackageDistributionNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw PackageDistributionError.nonHTTPResponse
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let key = name as? String else { continue }
            headers[key] = String(describing: value)
        }
        return .init(statusCode: http.statusCode, headers: headers, body: data, responseURL: http.url)
    }
}

private final class PackageDistributionNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Fixed public base-package channel. The app accepts only HTTPS and safe
/// channel components; it cannot be redirected by a manifest-controlled URL.
public struct PackageDistributionEndpoint: Sendable, Equatable {
    public let baseURL: URL
    public let channel: String

    public init(baseURL: URL, channel: String) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              Self.isSafeIdentifier(channel) else {
            throw PackageDistributionError.invalidEndpoint
        }
        self.baseURL = baseURL
        self.channel = channel
    }

    public func manifestURL() -> URL {
        baseURL
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("vault-classifier", isDirectory: true)
            .appendingPathComponent("channels", isDirectory: true)
            .appendingPathComponent(channel, isDirectory: true)
            .appendingPathComponent("manifest", isDirectory: false)
    }

    public func payloadURL(for manifest: ModelPackageManifest) -> URL {
        baseURL
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("vault-classifier", isDirectory: true)
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(manifest.packageID, isDirectory: true)
            .appendingPathComponent(String(manifest.releaseSequence), isDirectory: true)
            .appendingPathComponent(manifest.payloadSHA256, isDirectory: true)
            .appendingPathComponent("payload", isDirectory: false)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }
}

public enum PackageDistributionFetchOutcome: Sendable {
    case notModified(etag: String?)
    /// A candidate was fully signature/checksum/payload verified locally. The
    /// caller may still choose whether to stage it; this client never activates
    /// or replaces the currently running classifier.
    case verifiedCandidate(ModelPackageCandidate, etag: String?)
}

public enum PackageDistributionError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case nonHTTPResponse
    case transportFailure
    case redirectedResponse
    case unexpectedHTTPStatus(Int)
    case invalidContentType
    case manifestPayloadTooLarge
    case payloadTooLarge
    case malformedManifest
    case invalidNotModifiedResponse
    case payloadSizeMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "The package distribution endpoint is not a safe HTTPS channel."
        case .nonHTTPResponse: return "The package distribution transport did not return HTTP."
        case .transportFailure: return "The package distribution request could not be completed."
        case .redirectedResponse: return "The package distribution response changed URLs and was rejected."
        case .unexpectedHTTPStatus: return "The package distribution server returned an unexpected HTTP status."
        case .invalidContentType: return "The package distribution response did not use the expected JSON content type."
        case .manifestPayloadTooLarge: return "The package manifest response exceeded its local safety bound."
        case .payloadTooLarge: return "The package payload exceeded its local safety bound."
        case .malformedManifest: return "The package manifest response was malformed."
        case .invalidNotModifiedResponse: return "The package distribution server returned an invalid not-modified response."
        case .payloadSizeMismatch: return "The package payload size did not match its signed manifest."
        }
    }
}

/// Fetches only the future server's fixed public base-model contract. The
/// caller injects the public keyring, so this type has no private signing key,
/// account state, server token, browser data, or automatic background work.
public struct PackageDistributionClient: Sendable {
    public static let maximumManifestResponseBytes = 64 * 1_024

    private let transport: any PackageDistributionHTTPTransport
    private let validator: PackageManifestValidator

    public init(
        keyring: PackageSigningKeyring,
        transport: any PackageDistributionHTTPTransport = URLSessionPackageDistributionHTTPTransport()
    ) {
        self.transport = transport
        self.validator = .init(keyring: keyring)
    }

    /// Fetches a current signed manifest and, only after its signer is checked,
    /// its deterministic payload path. `304` produces no candidate and makes
    /// no payload request. Any outage or validation error leaves the active
    /// local package untouched.
    public func fetchLatestCandidate(
        from endpoint: PackageDistributionEndpoint,
        ifNoneMatch etag: String? = nil
    ) async throws -> PackageDistributionFetchOutcome {
        let manifestURL = endpoint.manifestURL()
        var headers = [
            "Accept": "application/json",
            "Cache-Control": "no-cache",
        ]
        if let etag = Self.validETag(etag) { headers["If-None-Match"] = etag }
        let manifestRequest = PackageDistributionHTTPRequest(url: manifestURL, headers: headers)
        let manifestResponse = try await perform(manifestRequest)
        try validateResponseURL(manifestResponse, expected: manifestURL)
        let returnedETag = Self.header(named: "ETag", in: manifestResponse.headers).flatMap(Self.validETag)

        if manifestResponse.statusCode == 304 {
            guard manifestResponse.body.isEmpty else {
                throw PackageDistributionError.invalidNotModifiedResponse
            }
            return .notModified(etag: returnedETag)
        }
        guard manifestResponse.statusCode == 200 else {
            throw PackageDistributionError.unexpectedHTTPStatus(manifestResponse.statusCode)
        }
        guard Self.isJSON(manifestResponse.headers), manifestResponse.body.count <= Self.maximumManifestResponseBytes else {
            throw manifestResponse.body.count > Self.maximumManifestResponseBytes
                ? PackageDistributionError.manifestPayloadTooLarge
                : PackageDistributionError.invalidContentType
        }
        let signedManifest = try Self.decodeStrictSignedManifest(manifestResponse.body)
        let manifest = try validator.verifyManifest(signedManifest)

        let payloadURL = endpoint.payloadURL(for: manifest)
        let payloadRequest = PackageDistributionHTTPRequest(
            url: payloadURL,
            headers: ["Accept": "application/json"]
        )
        let payloadResponse = try await perform(payloadRequest)
        try validateResponseURL(payloadResponse, expected: payloadURL)
        guard payloadResponse.statusCode == 200 else {
            throw PackageDistributionError.unexpectedHTTPStatus(payloadResponse.statusCode)
        }
        guard Self.isJSON(payloadResponse.headers) else {
            throw PackageDistributionError.invalidContentType
        }
        guard payloadResponse.body.count <= PackageManifestValidator.maximumPayloadByteCount else {
            throw PackageDistributionError.payloadTooLarge
        }
        guard payloadResponse.body.count == manifest.payloadByteCount else {
            throw PackageDistributionError.payloadSizeMismatch(expected: manifest.payloadByteCount, actual: payloadResponse.body.count)
        }
        let candidate = ModelPackageCandidate(signedManifest: signedManifest, payload: payloadResponse.body)
        _ = try validator.verify(candidate)
        return .verifiedCandidate(candidate, etag: returnedETag)
    }

    private func perform(_ request: PackageDistributionHTTPRequest) async throws -> PackageDistributionHTTPResponse {
        do {
            return try await transport.perform(request)
        } catch let error as PackageDistributionError {
            throw error
        } catch {
            throw PackageDistributionError.transportFailure
        }
    }

    private func validateResponseURL(_ response: PackageDistributionHTTPResponse, expected: URL) throws {
        guard response.responseURL == nil || response.responseURL == expected else {
            throw PackageDistributionError.redirectedResponse
        }
    }

    private static func isJSON(_ headers: [String: String]) -> Bool {
        guard let raw = header(named: "Content-Type", in: headers) else { return false }
        return raw.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/json"
    }

    private static func header(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func validETag(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 512,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            return nil
        }
        return value
    }

    private static func decodeStrictSignedManifest(_ data: Data) throws -> SignedModelPackageManifest {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw PackageDistributionError.malformedManifest
        }
        guard let envelope = raw as? [String: Any],
              Set(envelope.keys) == ["manifest", "algorithm", "signature"],
              let manifest = envelope["manifest"] as? [String: Any],
              Set(manifest.keys) == [
                "schemaVersion", "packageID", "releaseSequence", "releaseVersion", "taxonomyVersion",
                "modelVersion", "payloadSHA256", "payloadByteCount", "publishedAtMilliseconds", "signingKeyID",
              ],
              let releaseVersion = manifest["releaseVersion"] as? [String: Any],
              Set(releaseVersion.keys) == ["major", "minor", "patch"] else {
            throw PackageDistributionError.malformedManifest
        }
        do {
            return try JSONDecoder().decode(SignedModelPackageManifest.self, from: data)
        } catch {
            throw PackageDistributionError.malformedManifest
        }
    }
}
