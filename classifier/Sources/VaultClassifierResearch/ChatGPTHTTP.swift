import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import VaultClassifierCore

public struct ChatGPTHTTPClient: Sendable {
    public typealias Sender = @Sendable (URLRequest, @escaping @Sendable (Data) throws -> Void) async throws -> Void
    private let sender: Sender
    public init(sender: @escaping Sender = { request, consume in try await ChatGPTHTTP.send(request, consume: consume) }) { self.sender = sender }

    func data(_ plan: ChatGPTPlanProtocol.Request, token: String? = nil, limit: Int = 262144) async throws -> Data {
        let buffer = LockedData(limit: limit)
        try await sender(try request(plan, token: token)) { try buffer.append($0) }
        return buffer.value
    }

    func inference(_ plan: ChatGPTPlanProtocol.Request, token: String, maximumTextBytes: Int = 262144, withoutDeadline: Bool = false) async throws -> (String, Int?, [RuleAICitation]) {
        let stream = LockedStream(maximumTextBytes: maximumTextBytes)
        var prepared = try request(plan, token: token)
        if withoutDeadline { prepared.timeoutInterval = .infinity }
        try await sender(prepared) { try stream.append($0) }
        return try stream.finish()
    }

    private func request(_ plan: ChatGPTPlanProtocol.Request, token: String?) throws -> URLRequest {
        var request = URLRequest(url: plan.url)
        request.httpMethod = plan.method; request.httpBody = plan.body
        request.timeoutInterval = 60
        if let contentType = plan.contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue(plan.url.path.hasSuffix("/responses") ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let token {
            guard plan.url.scheme == "https", plan.url.host == "api.openai.com", !token.isEmpty,
                  !token.contains("\r"), !token.contains("\n") else { throw ChatGPTPlanError.invalidAuthorization }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

private final class LockedData: @unchecked Sendable {
    let limit: Int; private let lock = NSLock(); private var data = Data()
    init(limit: Int) { self.limit = limit }
    func append(_ bytes: Data) throws {
        try lock.withLock {
            guard bytes.count <= limit - data.count else { throw ChatGPTPlanError.responseTooLarge }
            data.append(bytes)
        }
    }
    var value: Data { lock.withLock { data } }
}

private final class LockedStream: @unchecked Sendable {
    private let lock = NSLock(); private var parser = ChatGPTPlanStream()
    private let maximumTextBytes: Int
    init(maximumTextBytes: Int) { self.maximumTextBytes = maximumTextBytes }
    func append(_ bytes: Data) throws { try lock.withLock { try parser.append(bytes); if parser.text.utf8.count > maximumTextBytes { throw ChatGPTPlanError.responseTooLarge } } }
    func finish() throws -> (String, Int?, [RuleAICitation]) { try lock.withLock { (try parser.finish(), parser.totalTokens, parser.citations) } }
}

/// A fresh ephemeral session for one bounded request. It streams actual network
/// chunks and rejects redirects instead of forwarding credentials to a new URL.
public enum ChatGPTHTTP {
    static func validateResponse(_ response: URLResponse, streaming: Bool) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 400 { throw ChatGPTPlanError.rejectedRequest }
            if status == 401 { throw CloudClassificationError.signInRequired }
            if status == 429 { throw ChatGPTPlanError.usageUnavailable }
            if status == 408 || (500...599).contains(status ?? 0) { throw ChatGPTPlanError.transientResponse }
            throw ChatGPTPlanError.failedResponse
        }
        guard streaming else { return }
        // The live plan route can omit Content-Type while sending valid SSE.
        // An explicit conflicting type is rejected; an absent type still must
        // pass bounded SSE framing and response.completed validation downstream.
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard contentType.isEmpty || contentType == "text/event-stream" else { throw ChatGPTPlanError.invalidResponse }
    }

    public static func send(_ request: URLRequest, consume: @escaping @Sendable (Data) throws -> Void) async throws {
        let sink = ResponseSink(consume: consume)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in sink.start(request, continuation: continuation) }
        }, onCancel: { sink.cancel() })
    }
}

private final class ResponseSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let consume: @Sendable (Data) throws -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var ended = false
    init(consume: @escaping @Sendable (Data) throws -> Void) { self.consume = consume }
    func start(_ request: URLRequest, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        if request.timeoutInterval.isInfinite {
            configuration.timeoutIntervalForRequest = .infinity
            configuration.timeoutIntervalForResource = .infinity
        } else {
            configuration.timeoutIntervalForResource = 60
        }
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request); self.task = task
        lock.unlock(); task.resume()
    }
    func cancel() { lock.withLock { cancelled = true }; finish(.failure(CancellationError())) }
    private func finish(_ result: Result<Void, Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<Void, Error>?, URLSession?) in
            guard !ended else { return (nil, nil) }
            // Cancellation may precede start; start will observe cancelled.
            guard continuation != nil else { return (nil, nil) }
            ended = true
            let result = (continuation, session)
            continuation = nil; session = nil; task = nil
            return result
        }
        state.1?.invalidateAndCancel()
        state.0?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            try ChatGPTHTTP.validateResponse(response, streaming: dataTask.originalRequest?.url?.path.hasSuffix("/responses") == true)
        } catch {
            completionHandler(.cancel); finish(.failure(error)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try consume(data) } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        } else { finish(.success(())) }
    }
}
