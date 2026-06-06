import Foundation

#if os(macOS)
import ApplicationServices
#endif

public struct MacPermissionState: Codable, Equatable, Sendable {
    public var accessibilityTrusted: Bool
    public var screenRecordingLikelyAvailable: Bool
    public var automationAvailable: Bool

    public init(
        accessibilityTrusted: Bool,
        screenRecordingLikelyAvailable: Bool,
        automationAvailable: Bool
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.screenRecordingLikelyAvailable = screenRecordingLikelyAvailable
        self.automationAvailable = automationAvailable
    }

    public static func current(promptForAccessibility: Bool = false) -> MacPermissionState {
        #if os(macOS)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: promptForAccessibility] as CFDictionary)
        return MacPermissionState(
            accessibilityTrusted: trusted,
            screenRecordingLikelyAvailable: false,
            automationAvailable: true
        )
        #else
        return MacPermissionState(
            accessibilityTrusted: false,
            screenRecordingLikelyAvailable: false,
            automationAvailable: false
        )
        #endif
    }
}
