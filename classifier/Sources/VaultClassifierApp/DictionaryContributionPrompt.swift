#if canImport(AppKit)
import AppKit

@MainActor
enum DictionaryContributionPrompt {
    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Help improve the creator dictionary"
        alert.informativeText = "Vault can occasionally send public creator IDs and their displayed subscriber/follower counts to customblocker.com. No titles, term names, browsing history or personal definitions are sent. Contributions are capped at 50 per day and retained for 7 days. You can disable this anytime in Classifier → Settings."
        let checkbox = NSButton(checkboxWithTitle: "Share creator IDs and subscriber counts", target: nil, action: nil)
        checkbox.state = .on; alert.accessoryView = checkbox
        alert.addButton(withTitle: "Save choice")
        alert.addButton(withTitle: "Don't share")
        return alert
    }
    static func present(_ supplied: NSAlert? = nil) -> Bool {
        let alert = supplied ?? makeAlert()
        let result = alert.runModal()
        return result == .alertFirstButtonReturn && (alert.accessoryView as? NSButton)?.state == .on
    }
}
#endif
