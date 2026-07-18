import Darwin
import Foundation

public struct LocalIPCRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var requestID: String
    public var envelope: NativeEnvelope

    public init(protocolVersion: Int = 1, envelope: NativeEnvelope) {
        self.protocolVersion = protocolVersion
        self.requestID = envelope.requestID
        self.envelope = envelope
    }
}

public struct LocalIPCResponse: Codable, Equatable, Sendable {
    public var requestID: String
    public var bridgeInfo: NativeBridgeInfoResponse?
    public var collectionInfo: NativeCollectionInfoResponse?
    public var collection: NativeCollectionResponse?
    public var classification: NativeClassificationResponse?
    public var correction: NativeCorrectionResponse?
    public var error: String?

    public init(requestID: String, bridgeInfo: NativeBridgeInfoResponse? = nil, collectionInfo: NativeCollectionInfoResponse? = nil, collection: NativeCollectionResponse? = nil, classification: NativeClassificationResponse? = nil, correction: NativeCorrectionResponse? = nil, error: String? = nil) {
        self.requestID = requestID
        self.bridgeInfo = bridgeInfo
        self.collectionInfo = collectionInfo
        self.collection = collection
        self.classification = classification
        self.correction = correction
        self.error = error
    }
}

public enum LocalIPCError: Error, LocalizedError, Sendable {
    case pathTooLong
    case socket(String)
    case malformedFrame
    case peerRejected
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: return "Local IPC socket path is too long."
        case .socket(let operation): return "Local IPC socket operation failed: \(operation)."
        case .malformedFrame: return "Local IPC frame is malformed."
        case .peerRejected: return "Local IPC peer was rejected."
        case .unavailable: return "Vault Classifier is not available locally."
        }
    }
}

/// A user-only Unix-domain socket. It is intentionally not a loopback HTTP service.
public final class LocalIPCServer {
    private let socketURL: URL
    private let handler: (LocalIPCRequest) -> LocalIPCResponse
    private let queue = DispatchQueue(label: "com.adamancia.vault-classifier.ipc", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var shouldRun = false

    public init(socketURL: URL, handler: @escaping (LocalIPCRequest) -> LocalIPCResponse) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener < 0 else { return }
        try preparePrivateSocketParent(at: socketURL.deletingLastPathComponent())
        try removeExistingSocket(at: socketURL)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalIPCError.socket("socket") }
        do {
            var address = try unixAddress(for: socketURL.path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, unixAddressLength(socketURL.path)) }
            }
            guard bound == 0 else { throw LocalIPCError.socket("bind") }
            guard chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else { throw LocalIPCError.socket("chmod") }
            guard listen(descriptor, 16) == 0 else { throw LocalIPCError.socket("listen") }
        } catch {
            close(descriptor)
            throw error
        }
        listener = descriptor
        shouldRun = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        lock.lock()
        let descriptor = listener
        listener = -1
        shouldRun = false
        lock.unlock()
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR); close(descriptor) }
        // Never unlink a regular or symlink replacement path. This server only
        // ever cleans up a Unix-domain socket endpoint.
        try? removeExistingSocket(at: socketURL)
    }

    private func acceptLoop() {
        while isRunning {
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return shouldRun && listener >= 0
    }

    private func serve(_ descriptor: Int32) {
        defer { close(descriptor) }
        guard peerHasCurrentUID(descriptor) else { return }
        do {
            let data = try readFrame(descriptor)
            let request = try JSONDecoder().decode(LocalIPCRequest.self, from: data)
            let response = request.protocolVersion == 1 && request.requestID.count <= 128
                ? handler(request)
                : LocalIPCResponse(requestID: request.requestID, error: "Unsupported IPC request.")
            try writeFrame(try JSONEncoder().encode(response), to: descriptor)
        } catch {
            let fallback = LocalIPCResponse(requestID: "", error: "Malformed local IPC request.")
            try? writeFrame(try JSONEncoder().encode(fallback), to: descriptor)
        }
    }
}

public enum LocalIPCClient {
    public static func send(_ request: LocalIPCRequest, socketURL: URL) throws -> LocalIPCResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalIPCError.socket("socket") }
        defer { close(descriptor) }
        var address = try unixAddress(for: socketURL.path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, unixAddressLength(socketURL.path)) }
        }
        guard connected == 0 else { throw LocalIPCError.unavailable }
        try writeFrame(try JSONEncoder().encode(request), to: descriptor)
        let data = try readFrame(descriptor)
        let response = try JSONDecoder().decode(LocalIPCResponse.self, from: data)
        guard response.requestID == request.requestID else { throw LocalIPCError.malformedFrame }
        return response
    }
}

private let localIPCMaximumFrameLength = 64 * 1_024

/// The app-owned socket lives below an App Support directory. The final parent
/// must be private even when it already existed (for example after an older
/// app build created it under a permissive umask), and a symlink may not stand
/// in for that parent.
private func preparePrivateSocketParent(at directory: URL) throws {
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let descriptor = directory.path.withCString {
        open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw LocalIPCError.socket("open socket parent") }
    defer { close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR else {
        throw LocalIPCError.socket("validate socket parent")
    }
    guard fchmod(descriptor, S_IRWXU) == 0 else {
        throw LocalIPCError.socket("chmod socket parent")
    }
}

/// Removes only a previous socket endpoint. Rejecting a regular file or a
/// symlink avoids silently deleting a path that is not owned by this server.
private func removeExistingSocket(at url: URL) throws {
    var metadata = stat()
    let inspected = lstat(url.path, &metadata)
    if inspected != 0 {
        guard errno == ENOENT else { throw LocalIPCError.socket("inspect existing socket") }
        return
    }
    guard (metadata.st_mode & S_IFMT) == S_IFSOCK else {
        throw LocalIPCError.socket("existing socket path")
    }
    guard unlink(url.path) == 0 else { throw LocalIPCError.socket("remove existing socket") }
}

private func unixAddress(for path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw LocalIPCError.pathTooLong }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    return address
}

private func unixAddressLength(_ path: String) -> socklen_t {
    socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
}

private func peerHasCurrentUID(_ descriptor: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    return getpeereid(descriptor, &uid, &gid) == 0 && uid == getuid()
}

private func readFrame(_ descriptor: Int32) throws -> Data {
    let header = try readExactly(4, from: descriptor)
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    guard length > 0, length <= localIPCMaximumFrameLength else { throw LocalIPCError.malformedFrame }
    return try readExactly(Int(length), from: descriptor)
}

private func writeFrame(_ data: Data, to descriptor: Int32) throws {
    guard data.count > 0, data.count <= localIPCMaximumFrameLength else { throw LocalIPCError.malformedFrame }
    var length = UInt32(data.count).littleEndian
    try withUnsafeBytes(of: &length) { try writeAll(Data($0), to: descriptor) }
    try writeAll(data, to: descriptor)
}

private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
    var output = Data(count: count)
    var offset = 0
    while offset < count {
        let readCount = output.withUnsafeMutableBytes { buffer -> Int in
            read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
        }
        guard readCount > 0 else { throw LocalIPCError.malformedFrame }
        offset += readCount
    }
    return output
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { buffer -> Int in
            write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
        }
        guard written > 0 else { throw LocalIPCError.socket("write") }
        offset += written
    }
}
