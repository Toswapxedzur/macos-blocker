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
        XCTAssertEqual(SharedBrowserBridgeProtocol.version, 3)
        XCTAssertEqual(SharedBrowserBridgeProtocol.address, "ws://127.0.0.1:8787")
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
}
