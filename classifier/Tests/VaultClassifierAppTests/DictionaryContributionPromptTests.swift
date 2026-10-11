#if canImport(AppKit)
import AppKit
import CoreGraphics
import XCTest
import VaultClassifierCore
@testable import VaultClassifierApp

@MainActor
final class DictionaryContributionPromptTests: XCTestCase {
    private static var preparedOwnedApplication = false
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
    private func window() -> NSWindow {
        if !Self.preparedOwnedApplication {
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            application.finishLaunching()
            application.activate(ignoringOtherApps: false)
            Self.preparedOwnedApplication = true
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil) // Own test application/window only.
        return window
    }

    private func drain() async {
        // Sheet completions run on a following AppKit turn, not synchronously.
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testUndecidedSheetDoesNotBlockNextMainTaskAndHasOneLifetime() async throws {
        let host = window()
        var saved: [Bool] = []
        let prompt = DictionaryContributionPrompt(choiceIsPending: { true }, saveChoice: { saved.append($0) })
        defer { prompt.shutdown(); host.close() }
        prompt.setHostWindow(host)
        let first = try XCTUnwrap(prompt.alert)
        prompt.setHostWindow(host)
        XCTAssertTrue(prompt.alert === first)
        var serviced = false
        DispatchQueue.main.async { serviced = true }
        await drain()
        XCTAssertTrue(serviced, "Startup must not enter an application-modal loop")
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(first.window.sheetParent === host)
    }

    func testSaveCheckedUncheckedAndExplicitDecline() async throws {
        for (checked, button, expected) in [(true, 0, true), (false, 0, false), (true, 1, false)] {
            let host = window()
            var saved: [Bool] = []
            let prompt = DictionaryContributionPrompt(choiceIsPending: { true }, saveChoice: { saved.append($0) })
            defer { prompt.shutdown(); host.close() }
            prompt.setHostWindow(host)
            let alert = try XCTUnwrap(prompt.alert)
            let checkbox = try XCTUnwrap(alert.accessoryView as? NSButton)
            XCTAssertEqual(checkbox.state, .on)
            checkbox.state = checked ? .on : .off
            alert.buttons[button].performClick(nil) // Actual owned fixture button.
            await drain()
            XCTAssertEqual(saved, [expected])
        }
    }

    func testNoWindowAndReturningChoiceDoNotShowOrSave() {
        var pending = true
        var saved: [Bool] = []
        let prompt = DictionaryContributionPrompt(choiceIsPending: { pending }, saveChoice: { saved.append($0) })
        defer { prompt.shutdown() }
        prompt.setHostWindow(nil)
        XCTAssertNil(prompt.alert)
        let host = window(); defer { host.close() }
        pending = false
        prompt.setHostWindow(host)
        XCTAssertNil(prompt.alert)
        XCTAssertTrue(saved.isEmpty)
    }

    func testNormalExternalChoiceInvalidatesDisplayedAndQueuedResponses() async throws {
        let host = window(); defer { host.close() }
        var pending = true
        var saved: [Bool] = []
        let prompt = DictionaryContributionPrompt(choiceIsPending: { pending }, saveChoice: { saved.append($0) })
        defer { prompt.shutdown() }
        prompt.setHostWindow(host)
        let question = try XCTUnwrap(prompt.alert)
        // The authoritative external choice precedes a delayed old button.
        // endSheet may complete synchronously, so don't assume it queues work.
        pending = false
        prompt.choiceChanged()
        question.buttons[0].performClick(nil)
        await drain()
        XCTAssertNil(prompt.alert)
        XCTAssertTrue(saved.isEmpty, "An old checked Save must not re-enable a newer declined choice")
        prompt.setHostWindow(host)
        XCTAssertNil(prompt.alert)
    }

    func testHostCloseAndReplacementCannotSaveOldSheet() async throws {
        let first = window(), replacement = window()
        defer { first.close(); replacement.close() }
        var saved: [Bool] = []
        let prompt = DictionaryContributionPrompt(choiceIsPending: { true }, saveChoice: { saved.append($0) })
        defer { prompt.shutdown() }
        prompt.setHostWindow(first)
        let old = try XCTUnwrap(prompt.alert)
        prompt.setHostWindow(replacement)
        await drain()
        XCTAssertFalse(prompt.alert === old)
        XCTAssertTrue(prompt.alert?.window.sheetParent === replacement)
        replacement.close()
        await drain()
        XCTAssertNil(prompt.alert)
        XCTAssertTrue(saved.isEmpty)
    }

    func testQuitSuspendResumeAndShutdownNeverRecordsDismissal() async throws {
        let host = window(); defer { host.close() }
        var saved: [Bool] = []
        let prompt = DictionaryContributionPrompt(choiceIsPending: { true }, saveChoice: { saved.append($0) })
        defer { prompt.shutdown() }
        prompt.setHostWindow(host)
        XCTAssertNotNil(prompt.alert)
        prompt.suspend()
        await drain()
        XCTAssertNil(prompt.alert)
        prompt.setHostWindow(host)
        XCTAssertNil(prompt.alert)
        prompt.resume() // The existing linked Quit warning was cancelled.
        XCTAssertNotNil(prompt.alert)
        prompt.shutdown() // Confirmed/unlinked Quit.
        await drain()
        XCTAssertNil(prompt.alert)
        prompt.resume(); prompt.setHostWindow(host)
        XCTAssertNil(prompt.alert)
        XCTAssertTrue(saved.isEmpty)
    }

    func testFailedChoiceDoesNotAutomaticallyRepromptOrMarkItMade() async throws {
        let host = window(); defer { host.close() }
        var attempts = 0
        let prompt = DictionaryContributionPrompt(choiceIsPending: { true }, saveChoice: { _ in attempts += 1 })
        defer { prompt.shutdown() }
        prompt.setHostWindow(host)
        let alert = try XCTUnwrap(prompt.alert)
        alert.buttons[0].performClick(nil)
        await drain()
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(prompt.alert)
        // Inject the normal lifecycle callback for a deterministic unit
        // boundary. This is not evidence of a genuine desktop key event.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: host)
        await drain()
        XCTAssertNil(prompt.alert, "The normal key callback must not spontaneously retry a failed Save")
        prompt.setHostWindow(host)
        XCTAssertNil(prompt.alert, "Repeated same-host attachment must not retry a failed Save")
        XCTAssertEqual(attempts, 1)
    }

    func testFailedSaveAllowsHostReopenAndCancelledQuitRetry() async throws {
        let host = window(), reopened = window()
        defer { host.close(); reopened.close() }
        var attempts = 0
        let prompt = DictionaryContributionPrompt(choiceIsPending: { true }, saveChoice: { _ in attempts += 1 })
        defer { prompt.shutdown() }
        prompt.setHostWindow(host)
        let first = try XCTUnwrap(prompt.alert)
        first.buttons[0].performClick(nil)
        await drain()
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(prompt.alert)
        host.close()
        prompt.setHostWindow(reopened)
        let second = try XCTUnwrap(prompt.alert)
        XCTAssertFalse(first === second)
        XCTAssertEqual(attempts, 1, "Host reopening is not itself a contribution choice")
        second.buttons[0].performClick(nil)
        await drain()
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(prompt.alert)
        prompt.suspend()
        prompt.resume() // Existing linked Quit warning cancellation.
        XCTAssertNotNil(prompt.alert)
        XCTAssertEqual(attempts, 2, "Cancelling Quit must not record a contribution choice")
    }

    func testGenuineKeyEventAfterFailedChoiceRequiresAvailableDesktop() async throws {
        let host = window(); defer { host.close() }
        let otherOwnedWindow = window(); defer { otherOwnedWindow.close() }
        var pending = true, attempts = 0
        var hostKeyEvents = 0
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                              object: host, queue: .main) { _ in
            MainActor.assumeIsolated { hostKeyEvents += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let prompt = DictionaryContributionPrompt(choiceIsPending: { pending }, saveChoice: { _ in attempts += 1 })
        defer { prompt.shutdown() }
        prompt.setHostWindow(host)
        let alert = try XCTUnwrap(prompt.alert)
        alert.buttons[0].performClick(nil)
        await drain()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(pending)
        XCTAssertNil(prompt.alert, "A persistence refusal must not create an automatic prompt loop")
        // AppKit restores key status after a sheet, and later ordinary host
        // focus events must not spontaneously retry the rejected choice.
        otherOwnedWindow.makeKey()
        host.makeKey()
        await drain()
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let screenLocked = session?["CGSSessionScreenIsLocked"] as? Bool
        print("Owned AppKit prerequisite: active=\(NSApplication.shared.isActive) running=\(NSApplication.shared.isRunning) canBecomeKey=\(host.canBecomeKey) isKey=\(host.isKeyWindow) keyEvents=\(hostKeyEvents) screenLocked=\(String(describing: screenLocked))")
        if hostKeyEvents == 0, screenLocked == true {
            throw XCTSkip("The actual test desktop is locked; genuine host key-event acceptance is unverified")
        }
        XCTAssertGreaterThan(hostKeyEvents, 0, "A genuine owned-window key notification is an explicit prerequisite")
        XCTAssertNil(prompt.alert, "Regaining key status must not retry a failed Save")
        XCTAssertEqual(attempts, 1)
        pending = false
        prompt.choiceChanged()
    }

    func testAcceptedViewModelChoiceCallbackIsSharedByValidatedActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var observed: [Bool] = []
        model.onDictionaryContributionChoiceChanged = {
            observed.append(model.coordinator?.snapshot().settings.dictionaries.contributionChoiceMade == true)
        }
        model.completeDictionaryOnboarding(enabled: false)
        XCTAssertNil(model.issue)
        XCTAssertEqual(observed, [true])
        XCTAssertFalse(try XCTUnwrap(model.localState?.settings.dictionaries).contributionEnabled)
        XCTAssertThrowsError(try model.saveDictionarySettings(mode: "retired", cacheSize: 0, contributionEnabled: true, choiceMade: true))
        XCTAssertEqual(observed, [true], "Refused settings must not announce a successful choice")
        await model.shutdown()
    }
    func testFutureSchemaOnboardingRefusalPreservesBytesStateAndUploadGate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = try VaultClassifierViewModel(headlessVaultDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        LocalStateFile.flushAllPendingWrites()
        let original = try XCTUnwrap(model.coordinator?.snapshot().settings)
        XCTAssertFalse(original.dictionaries.contributionChoiceMade)
        let file = directory.appendingPathComponent("state.json")
        let future = Data(#"{"schemaVersion":99,"future":{"keep":"unmodified"}}"#.utf8)
        try future.write(to: file)
        var callbacks = 0
        model.onDictionaryContributionChoiceChanged = { callbacks += 1 }
        model.completeDictionaryOnboarding(enabled: false)
        XCTAssertNotNil(model.issue)
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(model.coordinator?.snapshot().settings, original,
                       "A rejected settings save must not record a choice in memory")
        XCTAssertEqual(try Data(contentsOf: file), future)
        XCTAssertFalse(try XCTUnwrap(model.dictionaryService?.disk.settings()).contributionEnabled,
                       "Explicit disable closes the upload gate even when storage refuses writes")
        await model.shutdown()
        XCTAssertEqual(try Data(contentsOf: file), future)
    }

}
#endif
