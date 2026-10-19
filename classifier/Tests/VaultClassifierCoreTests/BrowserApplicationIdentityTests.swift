import XCTest
import VaultClassifierCore
@testable import VaultClassifierBridge
#if os(macOS)
import Darwin
#endif

final class BrowserApplicationIdentityTests: XCTestCase {
    private let secret = Data((0..<32).map(UInt8.init))
    private let challenge = String(repeating: "c", count: 43)

    func testCrossPlatformProofVectors() throws {
        let vectors = [
            ("chrome", "mac-bundle-id", "com.google.chrome", "J6JMoNpqNu5WcoLT-AFCfoxNv1AKkPbU0C7zyGfVSaY"),
            ("chrome", "mac-bundle-id", "com.brave.browser", "8qGFArHs-bHihNmCCVmlP4gJrBlUbu1R0evjMFODVDw"),
            ("safari", "mac-bundle-id", "com.apple.safari", "UUEu-8gGeBMcJFlypPwNE7CalrMQzVpqiGSBhgDizGI"),
            ("edge", "windows-exe-sha256", String(repeating: "0", count: 64), "WFnmBt-qxvOEZgwSqv0A92VUKFTNOJFuL4MwI05dJ_k")
        ]
        for (program, kind, value, proof) in vectors {
            let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: kind, value: value))
            XCTAssertEqual(try LocalHubAuthentication.makeBrowserIdentityProof(program: program, challenge: challenge, identity: identity, secret: secret), proof)
            XCTAssertTrue(LocalHubAuthentication.verifyBrowserIdentityProof(program: program, challenge: challenge, identity: identity, proof: proof, secret: secret))
            XCTAssertNotEqual(try LocalHubAuthentication.makeProof(program: program, challenge: challenge, secret: secret), proof)
        }
    }

    func testCanonicalIdentityBounds() {
        XCTAssertNotNil(BrowserApplicationIdentity(kind: "mac-bundle-id", value: String(repeating: "a", count: 255)))
        for value in ["", ".com.chrome", "-chrome", "com.google.Chrome", "com.google.chrome\nprogram=edge", "com.é", "com app", String(repeating: "a", count: 256)] {
            XCTAssertNil(BrowserApplicationIdentity(kind: "mac-bundle-id", value: value))
        }
        for value in [String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            XCTAssertNil(BrowserApplicationIdentity(kind: "windows-exe-sha256", value: value))
        }
        XCTAssertNil(BrowserApplicationIdentity(kind: "ua", value: "chrome"))
    }

    func testVersionRequiresActualInteger() {
        XCTAssertTrue(LocalHubAuthentication.isBrowserIdentityVersion(1))
        let values: [Any] = [true, false, 0, 2, 1.0, 1.5, UInt64.max, "1", NSNull()]
        for bad in values {
            XCTAssertFalse(LocalHubAuthentication.isBrowserIdentityVersion(bad), "\(bad)")
        }
        XCTAssertFalse(LocalHubAuthentication.isBrowserIdentityVersion(nil))
        for text in ["true", "1.0", "1.5", "\"1\"", "null"] {
            let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            XCTAssertFalse(LocalHubAuthentication.isBrowserIdentityVersion(value), text)
        }
        let integer = try? JSONSerialization.jsonObject(with: Data("1".utf8), options: [.fragmentsAllowed])
        XCTAssertTrue(LocalHubAuthentication.isBrowserIdentityVersion(integer))
    }

    func testAttestationCannotLoseOrChangeBoundFields() throws {
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.google.chrome"))
        let proof = try LocalHubAuthentication.makeBrowserIdentityProof(program: "chrome", challenge: challenge, identity: identity, secret: secret)
        let object: [String: Any] = ["v": 1, "kind": identity.kind, "value": identity.value, "proof": proof]
        func verify(_ value: [String: Any]) -> BrowserApplicationIdentity? {
            LocalHubAuthentication.verifyBrowserIdentityAttestation(value, program: "chrome", challenge: challenge, secret: secret)
        }
        XCTAssertEqual(verify(object), identity)
        for key in object.keys { var changed = object; changed.removeValue(forKey: key); XCTAssertNil(verify(changed)) }
        for (key, value) in [("v", true as Any), ("v", 1.5), ("kind", "windows-exe-sha256"), ("value", "com.brave.browser"), ("proof", String(repeating: "p", count: 43)), ("extra", "unbound")] {
            var changed = object; changed[key] = value; XCTAssertNil(verify(changed))
        }
        XCTAssertFalse(LocalHubAuthentication.verifyBrowserIdentityProof(program: "edge", challenge: challenge, identity: identity, proof: proof, secret: secret))
        XCTAssertFalse(LocalHubAuthentication.verifyBrowserIdentityProof(program: "chrome", challenge: String(repeating: "d", count: 43), identity: identity, proof: proof, secret: secret))
        XCTAssertFalse(LocalHubAuthentication.verifyBrowserIdentityProof(program: "chrome", challenge: challenge, identity: identity, proof: proof, secret: Data(repeating: 1, count: 32)))
        XCTAssertThrowsError(try LocalHubAuthentication.makeBrowserIdentityProof(program: "classifier", challenge: challenge, identity: identity, secret: secret))
        XCTAssertThrowsError(try LocalHubAuthentication.makeBrowserIdentityProof(program: "chrome", challenge: "bad", identity: identity, secret: secret))
    }

    #if os(macOS)
    private func evidence(parentID: String = "com.google.Chrome.helper", appID: String = "com.google.Chrome", bundleID: String = "com.google.Chrome", parentUID: uid_t = 503, parentBirth: UInt64 = 10, parentPID: pid_t = 100, path: String = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", hash: Data = Data([1])) -> BrowserParentEvidence {
        BrowserParentEvidence(
            host: BrowserParentProcess(pid: 101, parentPID: 100, uid: 503, seconds: 20, microseconds: 0, path: "/owned/NativeHost"),
            parent: BrowserParentProcess(pid: parentPID, parentPID: 1, uid: parentUID, seconds: parentBirth, microseconds: 0, path: path),
            parentSigningID: parentID, parentCDHash: hash, applicationPath: "/Applications/Google Chrome.app", applicationSigningID: appID, applicationCDHash: Data([2]), applicationBundleID: bundleID)
    }

    func testExistingParentPolicyAndActualApplicationMapping() throws {
        let chrome = try XCTUnwrap(NativeBrowserParentIdentity.applicationIdentity(evidence(), environment: .production))
        XCTAssertEqual(chrome.program, "chrome"); XCTAssertEqual(chrome.identity.value, "com.google.chrome")
        let edge = try XCTUnwrap(NativeBrowserParentIdentity.applicationIdentity(evidence(parentID: "com.microsoft.edgemac", appID: "com.microsoft.edgemac", bundleID: "com.microsoft.edgemac"), environment: .production))
        XCTAssertEqual(edge.program, "edge")
        XCTAssertNotNil(NativeBrowserParentIdentity.applicationIdentity(evidence(parentID: "org.chromium.Chromium", appID: "org.chromium.Chromium", bundleID: "org.chromium.Chromium"), environment: .production))
        for id in ["com.brave.Browser", "com.operasoftware.Opera"] {
            XCTAssertNotNil(NativeBrowserParentIdentity.applicationIdentity(evidence(parentID: id, appID: id, bundleID: id), environment: .production))
        }
        let automation = evidence(parentID: "Chromium Helper", appID: "Chromium", bundleID: "org.chromium.Chromium")
        XCTAssertNil(NativeBrowserParentIdentity.applicationIdentity(automation, environment: .production))
        XCTAssertNotNil(NativeBrowserParentIdentity.applicationIdentity(automation, environment: .development))
        XCTAssertNil(NativeBrowserParentIdentity.applicationIdentity(evidence(parentID: "com.vivaldi.Vivaldi", appID: "com.vivaldi.Vivaldi", bundleID: "com.vivaldi.Vivaldi"), environment: .production))
        // Current valid-signature/parent-identifier policy permits custom-signed
        // applications. Bind the verified actual bundle ID, not a guessed family.
        let custom = try XCTUnwrap(NativeBrowserParentIdentity.applicationIdentity(evidence(appID: "custom.valid.signature", bundleID: "com.example.CustomBrowser"), environment: .production))
        XCTAssertEqual(custom.program, "chrome")
        XCTAssertEqual(custom.identity.value, "com.example.custombrowser")
        XCTAssertNil(NativeBrowserParentIdentity.applicationIdentity(evidence(appID: "com.google.Chrome.helper"), environment: .production))
    }

    func testOriginalParentLeaseRefusesDriftAndUnavailableObservation() throws {
        let good = evidence()
        let bad = [evidence(parentUID: 0), evidence(parentBirth: 21), evidence(parentPID: 99), evidence(path: "/other/browser"), evidence(hash: Data([3])),
                   evidence(appID: "other.valid.signature"), evidence(bundleID: "com.brave.Browser")]
        for next in bad {
            var observations = [good, next]
            let lease = try XCTUnwrap(NativeBrowserParentIdentity(environment: .production) { observations.removeFirst() })
            XCTAssertNil(lease.identityForProof())
        }
        var count = 0
        let missing = try XCTUnwrap(NativeBrowserParentIdentity(environment: .production) { count += 1; return count == 1 ? good : nil })
        XCTAssertNil(missing.identityForProof())
        XCTAssertNil(NativeBrowserParentIdentity(environment: .production) { self.evidence(parentUID: 0) })
    }
    #endif
}
