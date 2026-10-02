import Foundation
import VaultClassifierApp
import VaultClassifierCore

private final class WorkerOutput: @unchecked Sendable {
    private let lock = NSLock()
    func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              bytes.count <= 16 * 1024 * 1024 else { return }
        bytes.append(0x0a)
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
            // Explicit hermetic mode for mini1 integration tests. Normal hosts
            // do not pass it and always start the production research/LLM stack.
            let arguments = CommandLine.arguments
            let testingDirectory: URL?
            if let index = arguments.firstIndex(of: "--testing-directory"), arguments.indices.contains(index + 1) {
                testingDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            } else {
                testingDirectory = nil
            }
            let service = try VaultClassifierWorkerService(testingDirectory: testingDirectory, emit: output.send)
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
                    let value = try service.handle(operation: operation, data: data)
                    output.send(["id": id, "ok": true, "value": value])
                } catch {
                    output.send(["id": requestID, "ok": false, "error": String(error.localizedDescription.prefix(512))])
                }
            }
            _ = try service.handle(operation: "hostEvent", data: ["kind": "flush"])
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
                    while let bytes = try FileHandle.standardInput.read(upToCount: 64 * 1024), !bytes.isEmpty {
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
