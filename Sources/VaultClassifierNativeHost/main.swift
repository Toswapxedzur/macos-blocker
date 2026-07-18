import AppKit
import Foundation
import VaultClassifierCore

private let nativeMaximumFrameLength = 64 * 1_024
private final class ReplayStore {
    private let url: URL
    private var window: NativeReplayWindow

    init(url: URL) {
        self.url = url
        self.window = (try? JSONDecoder().decode(NativeReplayWindow.self, from: Data(contentsOf: url))) ?? .init()
    }

    func verifyAndRecord(_ envelope: NativeEnvelope, secret: Data) throws {
        try window.verifyAndRecord(envelope, secret: secret)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(window).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private final class VaultClassifierNativeHost {
    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput
    private let vaultDirectory: URL
    private let socketURL: URL
    private let replayStore: ReplayStore

    init() {
        let appSupport = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        vaultDirectory = appSupport.appendingPathComponent("VaultClassifier", isDirectory: true)
        socketURL = vaultDirectory.appendingPathComponent("classifier-v1.sock")
        replayStore = ReplayStore(url: vaultDirectory.appendingPathComponent("native-replay.json"))
    }

    func run() {
        while let data = readNativeFrame() {
            let response = process(data)
            if let responseData = try? JSONEncoder().encode(response) {
                writeNativeFrame(responseData)
            }
        }
    }

    private func process(_ data: Data) -> NativeEnvelope {
        guard let envelope = try? JSONDecoder().decode(NativeEnvelope.self, from: data) else {
            return unsignedError(requestID: "", message: "Malformed native message.")
        }
        if envelope.kind == "pair" {
            return pair(envelope)
        }
        guard let secret = DevicePairingSecretStore.load() else {
            return unsignedError(requestID: envelope.requestID, message: "Extension is not paired with Vault Classifier.")
        }
        do {
            try replayStore.verifyAndRecord(envelope, secret: secret)
            switch envelope.kind {
            case "bridge-info":
                _ = try JSONDecoder().decode(NativeBridgeInfoRequest.self, from: envelope.bodyData())
                let response = try forwardBridgeInfo(requestID: envelope.requestID, envelope: envelope)
                var authenticated = try NativeEnvelope.unsigned(kind: "bridge-info-response", body: response, requestID: envelope.requestID)
                authenticated.sign(using: secret)
                return authenticated
            case "classify":
                let body = try JSONDecoder().decode(NativeClassificationRequest.self, from: envelope.bodyData())
                let response = try forwardClassification(body, requestID: envelope.requestID, envelope: envelope)
                var authenticated = try NativeEnvelope.unsigned(kind: "classification-response", body: response, requestID: envelope.requestID)
                authenticated.sign(using: secret)
                return authenticated
            case "correct":
                let body = try JSONDecoder().decode(NativeCorrectionRequest.self, from: envelope.bodyData())
                let response = try forwardCorrection(body, requestID: envelope.requestID, envelope: envelope)
                var authenticated = try NativeEnvelope.unsigned(kind: "correction-response", body: response, requestID: envelope.requestID)
                authenticated.sign(using: secret)
                return authenticated
            default:
                throw NativeProtocolError.malformed
            }
        } catch {
            return authenticatedError(requestID: envelope.requestID, message: error.localizedDescription, secret: secret)
        }
    }

    private func pair(_ envelope: NativeEnvelope) -> NativeEnvelope {
        do {
            guard envelope.protocolVersion == 1, envelope.requestID.count <= 128 else { throw NativeProtocolError.malformed }
            let request = try JSONDecoder().decode(NativePairRequest.self, from: envelope.bodyData())
            guard request.clientID.count >= 16, request.clientID.count <= 128 else { throw NativeProtocolError.malformed }
            let secret = try DevicePairingSecretStore.ensure()
            return try NativeEnvelope.unsigned(kind: "pair-response", body: NativePairResponse(secretBase64: secret.base64EncodedString()), requestID: envelope.requestID)
        } catch {
            return unsignedError(requestID: envelope.requestID, message: error.localizedDescription)
        }
    }

    private func forwardClassification(_ request: NativeClassificationRequest, requestID: String, envelope: NativeEnvelope) throws -> NativeClassificationResponse {
        let response = try forward(LocalIPCRequest(envelope: envelope), requestID: requestID)
        guard let classification = response.classification else { throw LocalIPCError.unavailable }
        return classification
    }

    private func forwardBridgeInfo(requestID: String, envelope: NativeEnvelope) throws -> NativeBridgeInfoResponse {
        let response = try forward(LocalIPCRequest(envelope: envelope), requestID: requestID)
        guard let bridgeInfo = response.bridgeInfo else { throw LocalIPCError.unavailable }
        return bridgeInfo
    }

    private func forwardCorrection(_ request: NativeCorrectionRequest, requestID: String, envelope: NativeEnvelope) throws -> NativeCorrectionResponse {
        let response = try forward(LocalIPCRequest(envelope: envelope), requestID: requestID)
        guard let correction = response.correction else { throw LocalIPCError.unavailable }
        return correction
    }

    private func forward(_ ipc: LocalIPCRequest, requestID: String) throws -> LocalIPCResponse {
        do {
            let response = try LocalIPCClient.send(ipc, socketURL: socketURL)
            if response.error == nil { return response }
            throw LocalIPCError.unavailable
        } catch {
            try launchVisibleAppIfConfigured()
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.25)
                if let response = try? LocalIPCClient.send(ipc, socketURL: socketURL), response.error == nil {
                    return response
                }
            }
            throw error
        }
    }

    private func launchVisibleAppIfConfigured() throws {
        // The registered host and product app are installed as sibling
        // executables. Resolving from the executable path avoids accepting an
        // environment-provided launch target from a browser process.
        let hostURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let appURL = hostURL.deletingLastPathComponent().appendingPathComponent("VaultClassifierApp")
        guard FileManager.default.isExecutableFile(atPath: appURL.path) else { throw LocalIPCError.unavailable }

        let process = Process()
        process.executableURL = appURL
        process.currentDirectoryURL = appURL.deletingLastPathComponent()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func unsignedError(requestID: String, message: String) -> NativeEnvelope {
        (try? NativeEnvelope.unsigned(kind: "error", body: ["error": message], requestID: requestID, nonce: NativeEnvelope.randomNonce()))
            ?? NativeEnvelope(kind: "error", requestID: requestID, timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000), nonce: "invalid", bodyBase64: "", bodyHash: String(repeating: "0", count: 64))
    }

    private func authenticatedError(requestID: String, message: String, secret: Data) -> NativeEnvelope {
        var envelope = unsignedError(requestID: requestID, message: message)
        envelope.sign(using: secret)
        return envelope
    }

    private func readNativeFrame() -> Data? {
        let header = input.readData(ofLength: 4)
        guard header.count == 4 else { return nil }
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard length > 0, length <= nativeMaximumFrameLength else { return nil }
        let body = input.readData(ofLength: Int(length))
        return body.count == Int(length) ? body : nil
    }

    private func writeNativeFrame(_ data: Data) {
        guard data.count > 0, data.count <= nativeMaximumFrameLength else { return }
        var length = UInt32(data.count).littleEndian
        output.write(withUnsafeBytes(of: &length) { Data($0) })
        output.write(data)
    }
}

VaultClassifierNativeHost().run()
