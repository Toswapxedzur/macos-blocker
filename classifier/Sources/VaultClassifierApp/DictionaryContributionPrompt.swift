#if canImport(AppKit)
import AppKit

@MainActor
final class DictionaryContributionPrompt {
    static func makeAlert(translate: (String, String) -> String = { _, fallback in fallback }) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = translate("native.dictionary.title", "Help improve the creator dictionary")
        alert.informativeText = translate("native.dictionary.macBody", "Vault can occasionally send public creator IDs and their displayed subscriber/follower counts to customblocker.com. No titles, term names, browsing history or personal definitions are sent. Contributions are capped at 50 per day and retained for 7 days. You can disable this anytime in Classifier → Settings.")
        let checkbox = NSButton(checkboxWithTitle: translate("native.dictionary.share", "Share creator IDs and subscriber counts"), target: nil, action: nil)
        checkbox.state = .on; alert.accessoryView = checkbox
        alert.addButton(withTitle: translate("native.dictionary.saveChoice", "Save choice"))
        alert.addButton(withTitle: translate("native.dictionary.decline", "Don't share"))
        // This optional question must not prevent AppKit from consulting the
        // normal Quit delegate. Dismissal still does not record a choice.
        alert.window.preventsApplicationTerminationWhenModal = false
        return alert
    }
    private let translate: (String, String) -> String
    private let choiceIsPending: () -> Bool
    private let saveChoice: (Bool) -> Void
    private weak var hostWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private(set) var alert: NSAlert?
    private var generation = 0
    private var suspended = false
    private var stopped = false
    private var awaitingExplicitRetry = false

    init(translate: @escaping (String, String) -> String = { _, fallback in fallback },
         choiceIsPending: @escaping () -> Bool, saveChoice: @escaping (Bool) -> Void) {
        self.translate = translate
        self.choiceIsPending = choiceIsPending
        self.saveChoice = saveChoice
    }

    /// The host supplies the window that actually contains its web view. Service
    /// startup never chooses an unrelated key window or waits for a UI response.
    func setHostWindow(_ window: NSWindow?) {
        guard !stopped else { return }
        if hostWindow !== window {
            dismiss()
            removeObservers()
            hostWindow = window
            awaitingExplicitRetry = false
            if let window {
                let center = NotificationCenter.default
                observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.presentIfNeeded() }
                })
                observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setHostWindow(nil) }
                })
            }
        }
        presentIfNeeded()
    }

    /// A successful choice from Settings/MCP makes any displayed question stale.
    func choiceChanged() {
        if !choiceIsPending() { dismiss() }
    }

    func suspend() {
        suspended = true
        dismiss()
    }

    func resume() {
        guard !stopped else { return }
        suspended = false
        awaitingExplicitRetry = false
        presentIfNeeded()
    }

    func shutdown() {
        stopped = true
        suspended = true
        dismiss()
        removeObservers()
        hostWindow = nil
    }

    private func presentIfNeeded() {
        guard !stopped, !suspended, !awaitingExplicitRetry, alert == nil, choiceIsPending(),
              let window = hostWindow, window.isVisible, window.attachedSheet == nil else { return }
        let question = Self.makeAlert(translate: translate)
        alert = question
        generation += 1
        let token = generation
        question.beginSheetModal(for: window) { [weak self, weak question] response in
            MainActor.assumeIsolated {
                guard let self, let question, self.generation == token, self.alert === question else { return }
                self.alert = nil
                self.generation += 1
                guard !self.stopped, !self.suspended, self.choiceIsPending() else { return }
                let enabled: Bool
                switch response {
                case .alertFirstButtonReturn:
                    enabled = (question.accessoryView as? NSButton)?.state == .on
                case .alertSecondButtonReturn:
                    enabled = false
                default:
                    return // Closing or shutting down is not a contribution choice.
                }
                // AppKit can restore the parent's key status while an explicit
                // choice is being saved. A refusal must not create a prompt loop.
                self.awaitingExplicitRetry = true
                self.saveChoice(enabled)
                self.awaitingExplicitRetry = self.choiceIsPending()
            }
        }
    }

    private func dismiss() {
        generation += 1
        guard let question = alert else { return }
        alert = nil // Invalidate before AppKit invokes an aborted completion.
        if let parent = question.window.sheetParent, parent === hostWindow {
            parent.endSheet(question.window, returnCode: .abort)
        }
        question.window.orderOut(nil)
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
#endif
