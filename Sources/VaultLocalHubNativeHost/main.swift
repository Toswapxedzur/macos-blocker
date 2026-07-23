import Darwin
import Foundation
import Security
import VaultClassifierCore

private let maximumFrameLength = 64 * 1_024
private let nativeHostOrigin = "chrome-extension://mcbmcmephdaapjepopobikobjmfdeamm/"
private let allowedParentIdentifiers: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.helper",
    "com.microsoft.edgemac", "com.microsoft.edgemac.helper",
    "org.chromium.Chromium", "org.chromium.Chromium.helper",
    "com.brave.Browser", "com.brave.Browser.helper",
    "com.operasoftware.Opera", "com.operasoftware.Opera.helper",
]

@main
struct VaultLocalHubNativeHost {
    static func main() {
        guard CommandLine.arguments.dropFirst().first == nativeHostOrigin,
              hasTrustedChromiumParent() else {
            return
        }
        while let request = readFrame() {
            guard let response = response(for: request),
                  let encoded = try? JSONSerialization.data(withJSONObject: response) else {
                return
            }
            writeFrame(encoded)
        }
    }

    private static func response(for data: Data) -> [String: Any]? {
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["kind"] as? String == "local-hub-challenge",
              (request["v"] as? NSNumber)?.intValue == LocalHubAuthentication.protocolVersion,
              let program = request["program"] as? String,
              LocalHubAuthentication.isBrowserProgram(program),
              let challenge = request["challenge"] as? String,
              let proof = try? LocalHubAuthentication.makeProof(program: program, challenge: challenge) else {
            return ["ok": false, "error": "authentication-unavailable"]
        }
        return ["ok": true, "proof": proof]
    }

    private static func hasTrustedChromiumParent() -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(getppid(), &path, UInt32(path.count)) > 0 else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: String(cString: path)) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return false
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let details = information as? [String: Any],
              let identifier = details[kSecCodeInfoIdentifier as String] as? String else {
            return false
        }
        return allowedParentIdentifiers.contains(identifier)
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
