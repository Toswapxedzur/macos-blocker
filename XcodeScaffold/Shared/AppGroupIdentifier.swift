import Foundation

/// Single source of truth for the App Group identifier. Add THIS FILE to the
/// app target AND every extension target in Xcode, and replace the value with
/// your real App Group (it must match the entitlements). Each target calls
/// `AppGroup.identifier = AppGroupIdentifier.value` at startup.
enum AppGroupIdentifier {
    static let value = "group.com.adamancia.vault"
}
