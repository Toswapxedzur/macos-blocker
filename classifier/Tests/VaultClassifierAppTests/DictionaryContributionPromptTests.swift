#if canImport(AppKit)
import AppKit
import XCTest
@testable import VaultClassifierApp

@MainActor
final class DictionaryContributionPromptTests: XCTestCase {
    func testLocalizedPromptPreservesConsentControlsAndDefault() throws {
        let strings = [
            "native.dictionary.title": "Wörterbuch verbessern",
            "native.dictionary.macBody": "Öffentliche IDs; höchstens 50 pro Tag, 7 Tage Aufbewahrung.",
            "native.dictionary.share": "Öffentliche IDs teilen",
            "native.dictionary.saveChoice": "Auswahl speichern",
            "native.dictionary.decline": "Nicht teilen"
        ]
        let alert = DictionaryContributionPrompt.makeAlert { key, fallback in strings[key] ?? fallback }
        XCTAssertEqual(alert.messageText, strings["native.dictionary.title"])
        XCTAssertEqual(alert.informativeText, strings["native.dictionary.macBody"])
        let checkbox = try XCTUnwrap(alert.accessoryView as? NSButton)
        XCTAssertEqual(checkbox.title, strings["native.dictionary.share"])
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertEqual(alert.buttons.map(\.title), ["Auswahl speichern", "Nicht teilen"])
    }
    func testNativeDefaultOnScreenCanSaveDisabledChoiceAndDecline() throws {
        guard ProcessInfo.processInfo.environment["VAULT_DICTIONARY_NATIVE_UI_TEST"] == "1" else { throw XCTSkip("Native modal requires mini1's desktop test window.") }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
        let alert = DictionaryContributionPrompt.makeAlert()
        let checkbox = try XCTUnwrap(alert.accessoryView as? NSButton)
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertTrue(alert.informativeText.contains("No titles, term names"))
        DispatchQueue.main.asyncAfter(deadline: .now()+0.2) {
            checkbox.state = .off; alert.buttons[0].performClick(nil)
        }
        XCTAssertFalse(DictionaryContributionPrompt.present(alert))
        let decline = DictionaryContributionPrompt.makeAlert()
        DispatchQueue.main.asyncAfter(deadline: .now()+0.2) { decline.buttons[1].performClick(nil) }
        XCTAssertFalse(DictionaryContributionPrompt.present(decline))
    }
}
#endif
