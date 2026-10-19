import Darwin
import Foundation
import Security
import VaultClassifierCore
import VaultClassifierBridge

private let maximumFrameLength = 64 * 1_024
#if VAULT_DEVELOPMENT_NATIVE_HOST
private let nativeHostEnvironment = VaultRuntimeEnvironment.development
#else
private let nativeHostEnvironment = VaultRuntimeEnvironment.production
#endif
private let nativeHostOrigin = nativeHostEnvironment.chromeExtensionOrigin
@main
struct VaultLocalHubNativeHost {
    static func main() {
        guard CommandLine.arguments.dropFirst().first == nativeHostOrigin else {
            return
        }
        let parent = NativeBrowserParentIdentity.capture(environment: nativeHostEnvironment)
        while let request = readFrame() {
            guard let response = response(for: request, parent: parent),
                  let encoded = try? JSONSerialization.data(withJSONObject: response) else {
                return
            }
            writeFrame(encoded)
        }
    }

    private static func response(for data: Data, parent: NativeBrowserParentIdentity?) -> [String: Any]? {
        let unavailable: [String: Any] = ["ok": false, "error": "browser-identity-unavailable", "browserIdentityVersion": 1]
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["kind"] as? String == "local-hub-challenge",
              (request["v"] as? NSNumber)?.intValue == LocalHubAuthentication.protocolVersion,
              request["browserIdentityVersion"] == nil || LocalHubAuthentication.isBrowserIdentityVersion(request["browserIdentityVersion"]),
              let program = request["program"] as? String,
              let actual = parent?.identityForProof(), actual.program == program,
              let challenge = request["challenge"] as? String,
              let secret = try? LocalHubAuthentication.sharedSecret(environment: nativeHostEnvironment),
              let proof = try? LocalHubAuthentication.makeProof(program: program, challenge: challenge, secret: secret),
              let identityProof = try? LocalHubAuthentication.makeBrowserIdentityProof(program: program, challenge: challenge, identity: actual.identity, secret: secret),
              let rechecked = parent?.identityForProof(), rechecked.program == actual.program, rechecked.identity == actual.identity else {
            return unavailable
        }
        return ["ok": true, "proof": proof, "browserIdentityVersion": 1,
                "browserIdentity": ["v": 1, "kind": actual.identity.kind, "value": actual.identity.value, "proof": identityProof]]
    }

    private static func readFrame() -> Data? {
        guard let header = readExactly(4) else { return nil }
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard length > 0, length <= maximumFrameLength else { return nil }
        return readExactly(Int(length))
    }

    private static func readExactly(_ length: Int) -> Data? {
        var data = Data()
        while data.count < length {
            let chunk = FileHandle.standardInput.readData(ofLength: length - data.count)
            guard !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }

    private static func writeFrame(_ data: Data) {
        guard data.count > 0, data.count <= maximumFrameLength else { return }
        var length = UInt32(data.count).littleEndian
        FileHandle.standardOutput.write(withUnsafeBytes(of: &length) { Data($0) })
        FileHandle.standardOutput.write(data)
    }
}
