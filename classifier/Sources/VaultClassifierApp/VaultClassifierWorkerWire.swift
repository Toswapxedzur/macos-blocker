import Foundation

/// Whole JSON-line responses are either delivered or explicitly refused. A
/// large MCP state/Activity response must never disappear or become partial.
public enum VaultClassifierWorkerWire {
    public static let maximumFrameBytes = 16 * 1024 * 1024

    public static func encoded(_ object: [String: Any]) -> Data {
        let candidate = JSONSerialization.isValidJSONObject(object)
            ? try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) : nil
        if var bytes = candidate, bytes.count <= maximumFrameBytes {
            bytes.append(0x0a)
            return bytes
        }
        let error = candidate == nil ? "worker-response-invalid" : "worker-response-too-large"
        let refusal: [String: Any]
        if let id = object["id"] as? String, !id.isEmpty, id.count <= 128 {
            refusal = ["id": id, "ok": false, "error": error]
        } else {
            refusal = ["event": "error", "error": error,
                       "sourceEvent": String((object["event"] as? String ?? "").prefix(128))]
        }
        var bytes = (try? JSONSerialization.data(withJSONObject: refusal, options: [.sortedKeys])) ?? Data()
        bytes.append(0x0a)
        return bytes
    }
}
