import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if !canImport(Combine)
// The portable service keeps the exact view-model state and action dispatch;
// publication is the worker's explicit snapshot callback rather than Combine.
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif

#if os(Windows)
/// FoundationNetworking has no AsyncBytes API on Windows. Preserve the Mac
/// cache's hard byte limit while streaming, including chunked HTTP responses.
private final class IconDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maximumBytes: Int
    let allowedContentTypes: Set<String>
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(data: Data, contentType: String), Error>?
    private var data = Data()
    private var contentType: String?
    private var session: URLSession?

    init(maximumBytes: Int, allowedContentTypes: Set<String>) {
        self.maximumBytes = maximumBytes
        self.allowedContentTypes = allowedContentTypes
    }

    func start(_ request: URLRequest, continuation: CheckedContinuation<(data: Data, contentType: String), Error>) {
        self.continuation = continuation
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let type = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.lowercased(),
              allowedContentTypes.contains(type), response.expectedContentLength <= Int64(maximumBytes) else {
            finish(.failure(URLError(.cannotDecodeContentData)))
            completionHandler(.cancel)
            return
        }
        lock.lock(); contentType = type; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        let fits = data.count + chunk.count <= maximumBytes
        if fits { data.append(chunk) }
        lock.unlock()
        if !fits { finish(.failure(URLError(.dataLengthExceedsMaximum))); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock(); let bytes = data; let type = contentType; lock.unlock()
        guard !bytes.isEmpty, let type else { finish(.failure(URLError(.zeroByteResource))); return }
        finish(.success((bytes, type)))
    }

    private func finish(_ result: Result<(data: Data, contentType: String), Error>) {
        lock.lock()
        let pending = continuation; continuation = nil
        let active = session; session = nil
        lock.unlock()
        pending?.resume(with: result)
        active?.invalidateAndCancel()
    }
}

enum BoundedSourceIconDownload {
    static func load(_ request: URLRequest, maximumBytes: Int, allowedContentTypes: Set<String>) async throws -> (data: Data, contentType: String) {
        let delegate = IconDownloadDelegate(maximumBytes: maximumBytes, allowedContentTypes: allowedContentTypes)
        return try await withCheckedThrowingContinuation { delegate.start(request, continuation: $0) }
    }
}
#endif
