#if canImport(AppKit)
import AppKit

@MainActor
enum DictionaryContributionPrompt {
    static func makeAlert(translate: (String, String) -> String = { _, fallback in fallback }) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = translate("native.dictionary.title", "Help improve the creator dictionary")
        alert.informativeText = translate("native.dictionary.macBody", "Vault can occasionally send public creator IDs and their displayed subscriber/follower counts to customblocker.com. No titles, term names, browsing history or personal definitions are sent. Contributions are capped at 50 per day and retained for 7 days. You can disable this anytime in Classifier → Knowledge.")
        let checkbox = NSButton(checkboxWithTitle: translate("native.dictionary.share", "Share creator IDs and subscriber counts"), target: nil, action: nil)
        checkbox.state = .on; alert.accessoryView = checkbox
        alert.addButton(withTitle: translate("native.dictionary.saveChoice", "Save choice"))
        alert.addButton(withTitle: translate("native.dictionary.decline", "Don't share"))
        return alert
    }
    static func present(_ supplied: NSAlert? = nil, translate: (String, String) -> String = { _, fallback in fallback }) -> Bool {
        let alert = supplied ?? makeAlert(translate: translate)
        let result = alert.runModal()
        return result == .alertFirstButtonReturn && (alert.accessoryView as? NSButton)?.state == .on
    }
}
#endif
