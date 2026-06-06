import Foundation

#if os(macOS)
import Security
#endif

/// Code-signing identity of an application bundle, used to build robust
/// `GuardTarget` match keys (so a blocked app can't be dodged by renaming or
/// moving its binary).
public struct MacCodeSigningInfo: Equatable, Sendable, Codable {
    public var teamIdentifier: String?
    public var signingIdentifier: String?

    public init(teamIdentifier: String? = nil, signingIdentifier: String? = nil) {
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
    }

    public var isEmpty: Bool {
        (teamIdentifier?.isEmpty ?? true) && (signingIdentifier?.isEmpty ?? true)
    }
}

public enum MacCodeSigning {
    /// Reads the Team ID / signing identifier for the bundle (or executable) at
    /// `path`. Returns `nil` when the item is unsigned or unreadable.
    public static func info(forItemAt path: String) -> MacCodeSigningInfo? {
        #if os(macOS)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path) as CFURL

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return nil
        }

        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoRef) == errSecSuccess,
              let dict = infoRef as? [String: Any] else {
            return nil
        }

        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let signing = dict[kSecCodeInfoIdentifier as String] as? String
        let result = MacCodeSigningInfo(teamIdentifier: team, signingIdentifier: signing)
        return result.isEmpty ? nil : result
        #else
        return nil
        #endif
    }
}
