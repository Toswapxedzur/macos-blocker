import Foundation
import VaultClassifierApp
import VaultClassifierCore

private final class WorkerOutput: @unchecked Sendable {
    private let lock = NSLock()
    func send(_ object: [String: Any]) {
        let bytes = VaultClassifierWorkerWire.encoded(object)
        lock.lock()
        defer { lock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: bytes)
    }
}

@main
private enum VaultClassifierWorkerMain {
    @MainActor static func main() async {
        let output = WorkerOutput()
        do {
            let service = try VaultClassifierWorkerService(emit: output.send)
            output.send(["event": "ready", "protocol": 1])
            service.publishState()
            for await bytes in inputLines() {
                var requestID = ""
                do {
                    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                          let id = object["id"] as? String, !id.isEmpty, id.count <= 128,
                          id.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
                          let operation = object["operation"] as? String, operation.count <= 128,
                          let data = object["data"] as? [String: Any] else { throw WorkerFrameError.invalidFrame }
                    requestID = id
                    let value = try await service.handle(operation: operation, data: data)
                    output.send(["id": id, "ok": true, "value": value])
                } catch {
                    output.send(["id": requestID, "ok": false, "error": String(error.localizedDescription.prefix(512))])
                }
            }
            _ = try await service.handle(operation: "hostEvent", data: ["kind": "flush"])
            LocalStateFile.flushAllPendingWrites()
        } catch {
            output.send(["event": "fatal", "error": String(error.localizedDescription.prefix(512))])
        }
    }

    private static func inputLines() -> AsyncStream<Data> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var pending = Data()
                do {
                    // Foundation's read(upToCount:) waits for the entire byte
                    // count on Windows pipes. availableData returns the next
                    // available chunk so small requests work before stdin EOF.
                    while true {
                        let bytes = FileHandle.standardInput.availableData
                        guard !bytes.isEmpty else { break }
                        pending.append(bytes)
                        guard pending.count <= 16 * 1024 * 1024 else { throw WorkerFrameError.frameTooLarge }
                        while let end = pending.firstIndex(of: 0x0a) {
                            let line = Data(pending[..<end])
                            pending.removeSubrange(...end)
                            if !line.isEmpty { continuation.yield(line) }
                        }
                    }
                    if !pending.isEmpty { continuation.yield(pending) }
                } catch {
                    // Closing a malformed/oversized stream prevents an attacker
                    // from growing the worker input buffer without a bound.
                }
                continuation.finish()
            }
        }
    }
}

private enum WorkerFrameError: String, Error, LocalizedError {
    case invalidFrame = "invalid-worker-frame"
    case frameTooLarge = "worker-frame-too-large"
    var errorDescription: String? { rawValue }
}
