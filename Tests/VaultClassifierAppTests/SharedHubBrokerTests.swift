import Foundation
import XCTest
@testable import VaultClassifierApp
@testable import VaultClassifierCore

final class SharedHubBrokerTests: XCTestCase {
    private func decodedStatePayload(from script: String) throws -> [String: Any] {
        let prefix = "atob('"
        let encodedStart = try XCTUnwrap(script.range(of: prefix)?.upperBound)
        let encodedEnd = try XCTUnwrap(script[encodedStart...].firstIndex(of: "'"))
        let encoded = String(script[encodedStart..<encodedEnd])
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testClassifierUsesTheFixedLocalHubContract() {
        XCTAssertEqual(SharedBrowserBridgeProtocol.version, 4)
        XCTAssertEqual(
            SharedBrowserBridgeProtocol.address(for: .production),
            "ws://127.0.0.1:8787"
        )
        XCTAssertEqual(
            SharedBrowserBridgeProtocol.address(for: .development),
            "ws://127.0.0.1:18787"
        )
        XCTAssertTrue(SharedBrowserBridgeProtocol.isAcceptedHubProgram("macapp"))
        XCTAssertTrue(SharedBrowserBridgeProtocol.isAcceptedHubProgram("classifier"))
        XCTAssertFalse(SharedBrowserBridgeProtocol.isAcceptedHubProgram("vault-broker"))
    }

    func testWebStateDeliveryUsesUTF8ForCollectedMetadata() throws {
        let title = "It’s Official: Marco Rubio is Running Venezuela"
        let script = try XCTUnwrap(VaultClassifierWebShell.stateUpdateJavaScript(payload: ["title": title]))
        XCTAssertTrue(script.contains("new TextDecoder()"))

        let restored = try decodedStatePayload(from: script)
        XCTAssertEqual(restored["title"] as? String, title)
    }

    func testWebBridgeAcceptsTheCompleteClassifierTypeForm() {
        // Name, platform/model selections, twelve LLM controls, and three
        // decision-priority controls currently produce 18 bounded fields.
        XCTAssertGreaterThanOrEqual(VaultClassifierWebShell.maximumWebActionDataFields, 18)
        XCTAssertLessThanOrEqual(VaultClassifierWebShell.maximumWebActionDataFields, 24)
    }

    func testWebStateDeliveryPreservesCollectedMetadataAcrossScripts() throws {
        let metadata = [
            "Español: acción y corazón",
            "Русский: привет, мир",
            "العربية: مرحبًا بالعالم",
            "עברית: שלום עולם",
            "हिन्दी: नमस्ते दुनिया",
            "বাংলা: হ্যালো বিশ্ব",
            "ਪੰਜਾਬੀ: ਸਤ ਸ੍ਰੀ ਅਕਾਲ",
            "தமிழ்: வணக்கம் உலகம்",
            "తెలుగు: హలో ప్రపంచం",
            "ไทย: สวัสดีชาวโลก",
            "中文：你好，世界",
            "日本語：こんにちは世界",
            "한국어: 안녕하세요 세계",
            "Ελληνικά: Γειά σου κόσμε",
            "Հայերեն: Բարեւ աշխարհ",
            "ქართული: გამარჯობა მსოფლიო",
            "🎬🌍",
        ]
        let script = try XCTUnwrap(VaultClassifierWebShell.stateUpdateJavaScript(payload: ["metadata": metadata]))
        let restored = try decodedStatePayload(from: script)
        XCTAssertEqual(restored["metadata"] as? [String], metadata)
    }

    func testWebStateScriptCarriesMonotonicPresentationRevision() throws {
        let script = try XCTUnwrap(
            VaultClassifierWebShell.stateUpdateJavaScript(
                payload: ["workspace": "classificationData"],
                presentationRevision: 42
            )
        )
        let restored = try decodedStatePayload(from: script)
        XCTAssertEqual((restored["presentationRevision"] as? NSNumber)?.uint64Value, 42)
    }

    func testWebStateDeliveryCoalescesWhileOneRenderIsInFlight() {
        var scheduled = [() -> Void]()
        var evaluations = [(script: String, completion: () -> Void)]()
        var builtRevisions = [UInt64]()
        let delivery = LatestWebStateDelivery(
            schedule: { scheduled.append($0) },
            makeScript: { revision in
                builtRevisions.append(revision)
                return "render-\(revision)"
            },
            evaluate: { script, completion in
                evaluations.append((script, completion))
            }
        )

        delivery.request()
        delivery.request()
        delivery.request()
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertTrue(evaluations.isEmpty)

        scheduled.removeFirst()()
        XCTAssertEqual(builtRevisions, [3])
        XCTAssertEqual(evaluations.map(\.script), ["render-3"])

        for _ in 0..<50 {
            delivery.request()
        }
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertEqual(evaluations.count, 1)

        evaluations.removeFirst().completion()
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(builtRevisions, [3, 53])
        XCTAssertEqual(evaluations.map(\.script), ["render-53"])
    }

    func testWebStateDeliveryRecoversFromAStuckWebContentProcess() {
        var scheduled = [() -> Void]()
        var completions = [() -> Void]()
        var builtRevisions = [UInt64]()
        let delivery = LatestWebStateDelivery(
            schedule: { scheduled.append($0) },
            makeScript: { revision in
                builtRevisions.append(revision)
                return "render-\(revision)"
            },
            evaluate: { _, completion in
                completions.append(completion)
            }
        )

        delivery.request()
        scheduled.removeFirst()()
        delivery.request()
        delivery.recoverAfterWebContentProcessTermination()
        XCTAssertEqual(scheduled.count, 1)

        completions.removeFirst()()
        XCTAssertEqual(scheduled.count, 1, "A stale WebKit callback must not finish the replacement delivery.")

        scheduled.removeFirst()()
        XCTAssertEqual(builtRevisions, [1, 3])
        XCTAssertEqual(completions.count, 1)
    }
}
