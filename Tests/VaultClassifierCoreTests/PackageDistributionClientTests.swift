import CryptoKit
import Foundation
import XCTest
@testable import VaultClassifierCore

final class PackageDistributionClientTests: XCTestCase {
    private enum StubTransportError: Error {
        case exhausted
    }

    private actor StubTransport: PackageDistributionHTTPTransport {
        private var responses: [PackageDistributionHTTPResponse]
        private var receivedRequests: [PackageDistributionHTTPRequest] = []

        init(responses: [PackageDistributionHTTPResponse]) {
            self.responses = responses
        }

        func perform(_ request: PackageDistributionHTTPRequest) async throws -> PackageDistributionHTTPResponse {
            receivedRequests.append(request)
            guard !responses.isEmpty else { throw StubTransportError.exhausted }
            return responses.removeFirst()
        }

        func requests() -> [PackageDistributionHTTPRequest] {
            receivedRequests
        }
    }

    private struct SignedFixture {
        var candidate: ModelPackageCandidate
        var keyring: PackageSigningKeyring
    }

    private func signedFixture() throws -> SignedFixture {
        var package = try SeedPackageLoader.bundled().package
        package.modelVersion = "vault-model-distribution-test"
        let payload = try JSONEncoder().encode(package)
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = ModelPackageManifest(
            packageID: package.packageID,
            releaseSequence: 42,
            releaseVersion: try .init(major: 2, minor: 4, patch: 1),
            taxonomyVersion: package.taxonomyVersion,
            modelVersion: package.modelVersion,
            payloadSHA256: PackageDigest.sha256Hex(payload),
            payloadByteCount: payload.count,
            publishedAtMilliseconds: 1_700_000_000_000,
            signingKeyID: "distribution-test-key"
        )
        let signature = try privateKey.signature(for: PackageManifestCodec.canonicalData(for: manifest))
        return .init(
            candidate: .init(signedManifest: .init(manifest: manifest, signature: signature), payload: payload),
            keyring: try .init([
                .init(keyID: "distribution-test-key", publicKey: privateKey.publicKey.rawRepresentation),
            ])
        )
    }

    private func endpoint() throws -> PackageDistributionEndpoint {
        try .init(baseURL: try XCTUnwrap(URL(string: "https://packages.example.test")), channel: "global-base")
    }

    private func jsonResponse(
        statusCode: Int = 200,
        body: Data,
        url: URL,
        etag: String? = nil
    ) -> PackageDistributionHTTPResponse {
        var headers = ["Content-Type": "application/json; charset=utf-8"]
        if let etag { headers["ETag"] = etag }
        return .init(statusCode: statusCode, headers: headers, body: body, responseURL: url)
    }

    func testValidSignedManifestAndPayloadUseFixedEndpointsAndReturnETag() async throws {
        let fixture = try signedFixture()
        let endpoint = try endpoint()
        let manifestBody = try JSONEncoder().encode(fixture.candidate.signedManifest)
        let transport = StubTransport(responses: [
            jsonResponse(body: manifestBody, url: endpoint.manifestURL(), etag: "\"base-v42\""),
            jsonResponse(body: fixture.candidate.payload, url: endpoint.payloadURL(for: fixture.candidate.signedManifest.manifest)),
        ])
        let client = PackageDistributionClient(keyring: fixture.keyring, transport: transport)

        let outcome = try await client.fetchLatestCandidate(from: endpoint, ifNoneMatch: "\"base-v41\"")

        guard case let .verifiedCandidate(candidate, etag) = outcome else {
            return XCTFail("Expected a fully verified model-package candidate.")
        }
        XCTAssertEqual(etag, "\"base-v42\"")
        XCTAssertEqual(candidate.signedManifest, fixture.candidate.signedManifest)
        XCTAssertEqual(candidate.payload, fixture.candidate.payload)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
        XCTAssertEqual(
            requests.map { $0.url.absoluteString },
            [
                "https://packages.example.test/api/v1/vault-classifier/channels/global-base/manifest",
                "https://packages.example.test/api/v1/vault-classifier/packages/\(fixture.candidate.signedManifest.manifest.packageID)/42/\(fixture.candidate.signedManifest.manifest.payloadSHA256)/payload",
            ]
        )
        XCTAssertEqual(requests[0].headers["Accept"], "application/json")
        XCTAssertEqual(requests[0].headers["Cache-Control"], "no-cache")
        XCTAssertEqual(requests[0].headers["If-None-Match"], "\"base-v41\"")
        XCTAssertEqual(requests[1].headers, ["Accept": "application/json"])
    }

    func testNotModifiedDoesNotRequestPayload() async throws {
        let fixture = try signedFixture()
        let endpoint = try endpoint()
        let transport = StubTransport(responses: [
            jsonResponse(statusCode: 304, body: .init(), url: endpoint.manifestURL(), etag: "\"base-v42\""),
        ])
        let client = PackageDistributionClient(keyring: fixture.keyring, transport: transport)

        let outcome = try await client.fetchLatestCandidate(from: endpoint, ifNoneMatch: "\"base-v42\"")

        guard case let .notModified(etag) = outcome else {
            return XCTFail("Expected an unchanged manifest result.")
        }
        XCTAssertEqual(etag, "\"base-v42\"")
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, endpoint.manifestURL())
        XCTAssertEqual(requests[0].headers["If-None-Match"], "\"base-v42\"")
    }

    func testInvalidManifestSignatureStopsBeforePayloadRequest() async throws {
        let fixture = try signedFixture()
        let endpoint = try endpoint()
        var invalidManifest = fixture.candidate.signedManifest
        invalidManifest.signature[invalidManifest.signature.startIndex] ^= 0x01
        let transport = StubTransport(responses: [
            jsonResponse(
                body: try JSONEncoder().encode(invalidManifest),
                url: endpoint.manifestURL()
            ),
        ])
        let client = PackageDistributionClient(keyring: fixture.keyring, transport: transport)

        do {
            _ = try await client.fetchLatestCandidate(from: endpoint)
            XCTFail("An invalid manifest signature must be rejected before downloading a payload.")
        } catch {
            XCTAssertEqual(error as? PackageManifestValidationError, .invalidSignature)
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, endpoint.manifestURL())
    }

    /// Non-secret interoperability fixture signed with Python `cryptography`
    /// Ed25519 over the restricted canonical JSON profile used by the server
    /// distribution helper. This guards the boundary rather than merely
    /// testing two Swift implementations of the same codec.
    func testPythonEd25519KnownVectorVerifiesWithSwiftCanonicalEncoding() throws {
        let envelope = Data("""
        {
          "manifest": {
            "schemaVersion": 1,
            "packageID": "vault-seed-test",
            "releaseSequence": 7,
            "releaseVersion": { "major": 1, "minor": 2, "patch": 3 },
            "taxonomyVersion": "taxonomy-1",
            "modelVersion": "model-7",
            "payloadSHA256": "7811c7b642ad8590b337ebd8e24438cfe36199cc86293449667a4382d2b6d103",
            "payloadByteCount": 21,
            "publishedAtMilliseconds": 1700000000000,
            "signingKeyID": "distribution-test-key"
          },
          "algorithm": "ed25519",
          "signature": "7hCgZ10jed9tz2OJM5TXByfPuQ6NP17Cu14SRV53SfITMqOuODBEHXmtX19ScMX/cFvY1wXisUaXPRgNGvpFCQ=="
        }
        """.utf8)
        let expectedCanonical = Data("""
        {"modelVersion":"model-7","packageID":"vault-seed-test","payloadByteCount":21,"payloadSHA256":"7811c7b642ad8590b337ebd8e24438cfe36199cc86293449667a4382d2b6d103","publishedAtMilliseconds":1700000000000,"releaseSequence":7,"releaseVersion":{"major":1,"minor":2,"patch":3},"schemaVersion":1,"signingKeyID":"distribution-test-key","taxonomyVersion":"taxonomy-1"}
        """.utf8)
        let publicKey = try XCTUnwrap(Data(base64Encoded: "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="))
        let signed = try JSONDecoder().decode(SignedModelPackageManifest.self, from: envelope)

        XCTAssertEqual(try PackageManifestCodec.canonicalData(for: signed.manifest), expectedCanonical)
        let keyring = try PackageSigningKeyring([
            .init(keyID: "distribution-test-key", publicKey: publicKey),
        ])
        XCTAssertEqual(
            try PackageManifestValidator(keyring: keyring).verifyManifest(signed),
            signed.manifest
        )
    }
}
