#if canImport(AppKit)
import AppKit
import XCTest
@testable import VaultClassifierApp

@MainActor
final class DictionaryContributionPromptTests: XCTestCase {
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
