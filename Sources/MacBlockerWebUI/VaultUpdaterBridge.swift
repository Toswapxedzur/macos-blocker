import Foundation

/// The desktop shell supplies updater actions without making the shared web UI
/// depend on Sparkle. The bridge is used only by the trusted editor document.
public enum VaultUpdaterBridge {
    public static var handle: ((String, Bool?) -> [String: Any])?
}
