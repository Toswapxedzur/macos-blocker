import Foundation

public struct PlatformCapabilities: Codable, Equatable, Sendable {
    public var screenTimeShielding: Bool
    public var deviceActivityMonitoring: Bool
    public var customShieldUI: Bool
    public var floatingStatusWindow: Bool
    public var accessibilityControl: Bool
    public var screenCaptureAssist: Bool
    public var arbitraryAppUIManipulation: Bool

    public init(
        screenTimeShielding: Bool,
        deviceActivityMonitoring: Bool,
        customShieldUI: Bool,
        floatingStatusWindow: Bool,
        accessibilityControl: Bool,
        screenCaptureAssist: Bool,
        arbitraryAppUIManipulation: Bool
    ) {
        self.screenTimeShielding = screenTimeShielding
        self.deviceActivityMonitoring = deviceActivityMonitoring
        self.customShieldUI = customShieldUI
        self.floatingStatusWindow = floatingStatusWindow
        self.accessibilityControl = accessibilityControl
        self.screenCaptureAssist = screenCaptureAssist
        self.arbitraryAppUIManipulation = arbitraryAppUIManipulation
    }

    public static let iOS = PlatformCapabilities(
        screenTimeShielding: true,
        deviceActivityMonitoring: true,
        customShieldUI: true,
        floatingStatusWindow: false,
        accessibilityControl: false,
        screenCaptureAssist: false,
        arbitraryAppUIManipulation: false
    )

    public static let iPadOS = PlatformCapabilities(
        screenTimeShielding: true,
        deviceActivityMonitoring: true,
        customShieldUI: true,
        floatingStatusWindow: false,
        accessibilityControl: false,
        screenCaptureAssist: false,
        arbitraryAppUIManipulation: false
    )

    public static let macOS = PlatformCapabilities(
        screenTimeShielding: true,
        deviceActivityMonitoring: true,
        customShieldUI: false,
        floatingStatusWindow: true,
        accessibilityControl: true,
        screenCaptureAssist: true,
        arbitraryAppUIManipulation: true
    )
}
