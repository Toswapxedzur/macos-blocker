#if os(macOS)
import Foundation
import XCTest
import VaultClassifierBridge
@testable import MacBlockerAppFeature

final class BrowserIdentityAdmissionTests: XCTestCase {
    private let secret = Data(repeating: 7, count: 32)
    private let challenge = String(repeating: "a", count: 43)

    private func hello(program: String = "chrome", identity: BrowserApplicationIdentity? = nil) throws -> [String: Any] {
        var value: [String: Any] = ["kind": "hello", "v": ConnectionHub.protocolVersion, "program": program, "challenge": challenge,
            "proof": try VaultClassifierBridge.LocalHubAuthentication.makeProof(program: program, challenge: challenge, secret: secret)]
        if let identity {
            value["browserIdentityVersion"] = 1
            value["browserIdentity"] = ["v": 1, "kind": identity.kind, "value": identity.value,
                "proof": try VaultClassifierBridge.LocalHubAuthentication.makeBrowserIdentityProof(
                    program: program, challenge: challenge, identity: identity, secret: secret)]
        }
        return value
    }

    private func rejection(_ value: [String: Any], appMajor: Int = 2) -> String? {
        ConnectionHub.helloRejectionReason(value, challenge: challenge, secret: secret, appMajor: appMajor)
    }

    func testLegacyBrowserAcceptedThroughNextMajorAndRetiredFollowingMajor() throws {
        let value = try hello()
        XCTAssertNil(rejection(value, appMajor: 2))
        XCTAssertNil(rejection(value, appMajor: 3))
        XCTAssertEqual(rejection(value, appMajor: 4), "browser-upgrade-required")
        XCTAssertNil(rejection(try hello(program: "classifier"), appMajor: 4))
    }

    func testOriginalUsageCapabilityIsIndependentStrictNumericDeclaration() throws {
        var value = try hello(program: "safari")
        value["originalUsageVersion"] = 1
        XCTAssertNil(rejection(value, appMajor: 5))
        for malformed: Any in [true, false, "1", 1.0, 1.25, 0, 2, NSNull()] {
            value["originalUsageVersion"] = malformed
            XCTAssertEqual(rejection(value), "invalid-original-usage-version")
        }
        value.removeValue(forKey: "originalUsageVersion")
        XCTAssertNil(rejection(value, appMajor: 5))
    }

    func testOrdinarySafariNeedsBaseProofButNoIdentityAtFutureMajors() throws {
        let value = try hello(program: "safari")
        XCTAssertNil(rejection(value, appMajor: 4))
        XCTAssertNil(rejection(value, appMajor: 5))
        XCTAssertNil(rejection(value, appMajor: 9))
        var invalid = value; invalid.removeValue(forKey: "proof")
        XCTAssertEqual(rejection(invalid, appMajor: 5), "authentication-failed")
        invalid = value; invalid["proof"] = String(repeating: "b", count: 43)
        XCTAssertEqual(rejection(invalid, appMajor: 5), "authentication-failed")
        invalid = value; invalid["browserIdentityVersion"] = 1
        XCTAssertEqual(rejection(invalid, appMajor: 5), "invalid-browser-identity")
        invalid = value; invalid["browserIdentity"] = ["v": 1, "kind": "mac-bundle-id", "value": "com.apple.safari", "proof": "invalid"]
        XCTAssertEqual(rejection(invalid, appMajor: 5), "invalid-browser-identity")
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.apple.safari"))
        invalid = try hello(program: "safari", identity: identity)
        var metadata = try XCTUnwrap(invalid["browserIdentity"] as? [String: Any]); metadata["value"] = "com.apple.safaritechnologypreview"; invalid["browserIdentity"] = metadata
        XCTAssertEqual(rejection(invalid, appMajor: 5), "invalid-browser-identity")
        XCTAssertEqual(rejection(try hello(program: "chrome"), appMajor: 4), "browser-upgrade-required")
    }

    func testAttestedMacIdentityAcceptedAtCurrentAndFutureMajors() throws {
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.google.chrome"))
        let value = try hello(identity: identity)
        XCTAssertNil(rejection(value))
        XCTAssertNil(rejection(value, appMajor: 4))
    }

    func testIdentityDoesNotReplaceMandatoryBaseAuthentication() throws {
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.google.chrome"))
        var value = try hello(identity: identity)
        value.removeValue(forKey: "proof")
        XCTAssertEqual(rejection(value), "authentication-failed")
        value["proof"] = String(repeating: "b", count: 43)
        XCTAssertEqual(rejection(value), "authentication-failed")
    }

    func testPartialOrMalformedMetadataCannotDowngradeToLegacy() throws {
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.google.chrome"))
        let valid = try hello(identity: identity)
        for field in ["browserIdentity", "browserIdentityVersion"] {
            var value = valid
            value.removeValue(forKey: field)
            XCTAssertEqual(rejection(value), "invalid-browser-identity")
        }
        let versions: [Any] = [true, 1.0, "1", 0, 2, NSNull()]
        for version in versions {
            var value = valid
            value["browserIdentityVersion"] = version
            XCTAssertEqual(rejection(value), "invalid-browser-identity")
        }
        var value = valid
        value["browserIdentity"] = NSNull()
        XCTAssertEqual(rejection(value), "invalid-browser-identity")
    }

    func testTamperedDescriptorProofAndObjectAreRejected() throws {
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.google.chrome"))
        let valid = try hello(identity: identity)
        let replacements: [(String, Any)] = [("value", "com.brave.browser"), ("proof", String(repeating: "b", count: 43)),
            ("kind", "windows-exe-sha256"), ("v", true), ("extra", "ignored")]
        for (field, replacement) in replacements {
            var value = valid
            var object = try XCTUnwrap(value["browserIdentity"] as? [String: Any])
            object[field] = replacement
            value["browserIdentity"] = object
            XCTAssertEqual(rejection(value), "invalid-browser-identity")
        }
    }

    func testAttestationIsBoundToProgramAndConnectionChallenge() throws {
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "mac-bundle-id", value: "com.google.chrome"))
        var value = try hello(identity: identity)
        value["program"] = "edge"
        value["proof"] = try VaultClassifierBridge.LocalHubAuthentication.makeProof(program: "edge", challenge: challenge, secret: secret)
        XCTAssertEqual(rejection(value), "invalid-browser-identity")
        value = try hello(identity: identity)
        let other = String(repeating: "b", count: 43)
        value["challenge"] = other
        value["proof"] = try VaultClassifierBridge.LocalHubAuthentication.makeProof(program: "chrome", challenge: other, secret: secret)
        XCTAssertEqual(ConnectionHub.helloRejectionReason(value, challenge: other, secret: secret), "invalid-browser-identity")
    }

    func testWrongPlatformAndClassifierMetadataAreRejected() throws {
        let identity = try XCTUnwrap(BrowserApplicationIdentity(kind: "windows-exe-sha256", value: String(repeating: "a", count: 64)))
        XCTAssertEqual(rejection(try hello(identity: identity)), "invalid-browser-identity")
        var value = try hello(program: "classifier")
        value["browserIdentityVersion"] = 1
        value["browserIdentity"] = ["v": 1]
        XCTAssertEqual(rejection(value), "invalid-browser-identity")
    }
}
#endif
