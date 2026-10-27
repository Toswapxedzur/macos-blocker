import Foundation
import VaultClassifierCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The public SIWC plan-usage wire contract. This does not read another app's
/// credentials, authorize an account, or enable cloud classification.
/// https://developers.openai.com/siwc/token-sharing-open-source
public enum ChatGPTPlanProtocol {
    public static let resource = "https://api.openai.com/v1"
    public static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let requiredPlanScope = "chatgpt.tokens.use.direct"

    public struct Model: Equatable, Sendable {
        public let identifier: String
        public let displayName: String
    }

    /// Inference bearer authentication belongs to the account client. Token
    /// endpoint bodies are sensitive and must never enter request/usage logs.
    public struct Request: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let url: URL
        public let method: String
        public let contentType: String?
        public let body: Data?
        public var description: String { "ChatGPT HTTP request (body redacted)" }
        public var debugDescription: String { description }
    }

    public struct AuthorizationAttempt: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let callbackURL: URL
        public let state: String
        public let nonce: String
        public let verifier: String
        public let issuedClientID: String?
        public let authorizationURL: URL
        public var description: String { "ChatGPT authorization attempt (redacted)" }
        public var debugDescription: String { description }

        /// The caller supplies fresh cryptographic random values and an S256
        /// challenge. The runtime must start the loopback listener first.
        public init(
            callbackURL: URL, hostID: String, state: String, nonce: String,
            verifier: String, s256Challenge: String, issuedClientID: String? = nil
        ) throws {
            guard callbackURL.scheme == "http", callbackURL.host == "127.0.0.1",
                  callbackURL.path == "/auth/callback", callbackURL.port != nil,
                  callbackURL.user == nil, callbackURL.password == nil,
                  callbackURL.query == nil, callbackURL.fragment == nil,
                  !hostID.isEmpty, !state.isEmpty, !nonce.isEmpty,
                  (43...128).contains(verifier.utf8.count), !s256Challenge.isEmpty,
                  issuedClientID != "dynamic_agent_client",
                  issuedClientID == nil || issuedClientID?.isEmpty == false else {
                throw ChatGPTPlanError.invalidAuthorization
            }
            self.callbackURL = callbackURL
            self.state = state
            self.nonce = nonce
            self.verifier = verifier
            self.issuedClientID = issuedClientID
            var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
            var values = [
                "client_id": issuedClientID ?? "dynamic_agent_client",
                "ext_agent_host_id": hostID,
                "response_type": "code",
                "redirect_uri": callbackURL.absoluteString,
                "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                "resource": ChatGPTPlanProtocol.resource,
                "state": state, "nonce": nonce,
                "code_challenge_method": "S256", "code_challenge": s256Challenge,
            ]
            if issuedClientID == nil { values["agent_name_hint"] = "Adamancia Vault" }
            components.queryItems = values.keys.sorted().map { URLQueryItem(name: $0, value: values[$0]) }
            authorizationURL = components.url!
        }

        /// State is checked before errors, codes or a client registration are
        /// used. The runtime must consume an attempt once and reject replay.
        public func exchangeRequest(for callback: URL) throws -> (clientID: String, request: Request) {
            guard callback.scheme == callbackURL.scheme, callback.host == callbackURL.host,
                  callback.port == callbackURL.port, callback.path == callbackURL.path,
                  callback.user == nil, callback.password == nil, callback.fragment == nil,
                  let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
                throw ChatGPTPlanError.invalidAuthorization
            }
            var values: [String: String] = [:]
            for item in query {
                guard values[item.name] == nil, let value = item.value else {
                    throw ChatGPTPlanError.invalidAuthorization
                }
                values[item.name] = value
            }
            guard let returnedState = values["state"] else { throw ChatGPTPlanError.invalidAuthorization }
            let actual = Array(returnedState.utf8), expected = Array(state.utf8)
            guard actual.count == expected.count,
                  zip(actual, expected).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { throw ChatGPTPlanError.invalidAuthorization }
            if values["error"] != nil { throw ChatGPTPlanError.authorizationDeclined }
            guard let code = values["code"], !code.isEmpty,
                  let clientID = values["client_id"] ?? issuedClientID,
                  !clientID.isEmpty, clientID != "dynamic_agent_client",
                  issuedClientID == nil || clientID == issuedClientID else {
                throw ChatGPTPlanError.invalidAuthorization
            }
            return (clientID, ChatGPTPlanProtocol.formRequest([
                "grant_type": "authorization_code", "client_id": clientID,
                "code": code, "code_verifier": verifier,
                "redirect_uri": callbackURL.absoluteString, "resource": ChatGPTPlanProtocol.resource,
            ]))
        }
    }

    public static func refreshRequest(clientID: String, refreshToken: String) throws -> Request {
        guard !clientID.isEmpty, clientID != "dynamic_agent_client", !refreshToken.isEmpty else {
            throw ChatGPTPlanError.invalidAuthorization
        }
        return formRequest([
            "grant_type": "refresh_token", "client_id": clientID,
            "refresh_token": refreshToken, "resource": resource,
        ])
    }

    private static func formRequest(_ values: [String: String]) -> Request {
        // Form encoding must escape '+' itself; URLComponents' query encoding
        // would otherwise turn a literal '+' in an OAuth value into a space.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = values.keys.sorted().map { key in
            key + "=" + values[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        return Request(url: tokenEndpoint, method: "POST", contentType: "application/x-www-form-urlencoded", body: Data(body.utf8))
    }

    public static func modelRequest() -> Request {
        Request(url: URL(string: resource + "/models")!, method: "GET", contentType: nil, body: nil)
    }

    /// SIWC uses `models/slug/display_name`, unlike the API-key model catalog.
    public static func parseModels(_ data: Data) throws -> [Model] {
        struct Catalog: Decodable { var models: [Entry] }
        struct Entry: Decodable { var slug: String; var display_name: String; var visibility: String }
        guard data.count <= 2_097_152, let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            throw ChatGPTPlanError.invalidResponse
        }
        var seen = Set<String>()
        return catalog.models.filter { $0.visibility == "list" && !$0.slug.isEmpty && seen.insert($0.slug).inserted }
            .map { Model(identifier: $0.slug, displayName: $0.display_name.isEmpty ? $0.slug : $0.display_name) }
    }

    public static func inferenceRequest(model: String, instructions: String, input: String) throws -> Request {
        guard !model.isEmpty, model.utf8.count <= 512,
              !instructions.isEmpty, !input.isEmpty else { throw ChatGPTPlanError.invalidRequest }
        let body: [String: Any] = [
            "model": model, "instructions": instructions,
            "input": [["role": "user", "content": input]],
            "store": false, "stream": true,
        ]
        return Request(url: URL(string: resource + "/responses")!, method: "POST", contentType: "application/json", body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }
}

public enum ChatGPTPlanError: Error, LocalizedError, Equatable, Sendable {
    case invalidAuthorization, authorizationDeclined, invalidRequest, invalidResponse
    case incompleteStream, failedResponse, usageUnavailable, responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorization: return "ChatGPT sign-in could not be validated. Start a new sign-in."
        case .authorizationDeclined: return "ChatGPT sign-in was declined."
        case .invalidRequest: return "The ChatGPT request is invalid."
        case .invalidResponse: return "ChatGPT returned an invalid response."
        case .incompleteStream: return "ChatGPT did not finish the response."
        case .failedResponse: return "ChatGPT could not complete the request."
        case .usageUnavailable: return "ChatGPT plan usage is currently unavailable or has reached its limit."
        case .responseTooLarge: return "The ChatGPT response exceeded the local response limit."
        }
    }
}

/// Incremental SSE framing. A partial answer is never accepted as a result;
/// usage errors after output deltas still fail the entire request. Buffering is
/// bounded in bytes, including ignored events, before JSON decoding.
public struct ChatGPTPlanStream: Sendable {
    public private(set) var text = ""
    public private(set) var citations: [RuleAICitation] = []
    public private(set) var totalTokens: Int?
    public private(set) var completed = false
    private var line = Data()
    private var eventLines: [String] = []
    private var receivedBytes = 0
    private var failure: ChatGPTPlanError?
    public static let maximumBytes = 1_048_576

    public init() {}

    public mutating func append(_ bytes: Data) throws {
        if let failure { throw failure }
        guard bytes.count <= Self.maximumBytes - receivedBytes else {
            failure = .responseTooLarge
            throw ChatGPTPlanError.responseTooLarge
        }
        receivedBytes += bytes.count
        do {
            for byte in bytes {
                if byte == 10 {
                    if line.last == 13 { line.removeLast() }
                    guard let value = String(data: line, encoding: .utf8) else { throw ChatGPTPlanError.invalidResponse }
                    line.removeAll(keepingCapacity: true)
                    if value.isEmpty { try dispatchEvent() }
                    else if value.hasPrefix("data:") {
                        var payload = String(value.dropFirst(5))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        eventLines.append(payload)
                    }
                } else { line.append(byte) }
            }
        } catch let error as ChatGPTPlanError { failure = error; throw error }
    }

    public mutating func finish() throws -> String {
        if let failure { throw failure }
        // Unterminated frames cannot establish successful completion.
        guard completed, line.isEmpty, eventLines.isEmpty else { throw ChatGPTPlanError.incompleteStream }
        return text
    }

    private mutating func dispatchEvent() throws {
        guard !eventLines.isEmpty else { return }
        let payload = eventLines.joined(separator: "\n")
        eventLines.removeAll(keepingCapacity: true)
        if payload == "[DONE]" { return } // Not a substitute for response.completed.
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw ChatGPTPlanError.invalidResponse }
        guard !completed else { throw ChatGPTPlanError.invalidResponse }
        switch type {
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else { throw ChatGPTPlanError.invalidResponse }
            text += delta
        case "response.completed":
            guard let response = object["response"] as? [String: Any],
                  response["status"] as? String == "completed", response["error"] == nil || response["error"] is NSNull else {
                throw ChatGPTPlanError.invalidResponse
            }
            let output = response["output"] as? [[String: Any]] ?? []
            if output.contains(where: { item in
                (item["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "refusal" }
            }) { throw ChatGPTPlanError.failedResponse }
            let final = output.filter { $0["type"] as? String == "message" && $0["role"] as? String == "assistant" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }.joined()
            if !final.isEmpty { text = final }
            citations = RuleAIReply.citations(in: response)
            let usage = response["usage"] as? [String: Any]
            if let count = usage?["total_tokens"] as? Int, count >= 0 { totalTokens = count }
            completed = true
        case "response.failed", "error":
            let response = object["response"] as? [String: Any]
            let error = (response?["error"] ?? object["error"]) as? [String: Any]
            let code = error?["code"] as? String ?? object["code"] as? String
            if code == "subscription_sharing_usage_limit_exceeded" || code == "subscription_sharing_usage_unavailable" {
                throw ChatGPTPlanError.usageUnavailable
            }
            throw ChatGPTPlanError.failedResponse
        case "response.incomplete": throw ChatGPTPlanError.incompleteStream
        default: break
        }
    }
}
