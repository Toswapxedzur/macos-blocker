#if os(macOS)
import Darwin
import Foundation
import Security
import VaultClassifierCore

struct BrowserParentProcess: Equatable {
    let pid: pid_t
    let parentPID: pid_t
    let uid: uid_t
    let seconds: UInt64
    let microseconds: UInt64
    let path: String
}

struct BrowserParentEvidence: Equatable {
    let host: BrowserParentProcess
    let parent: BrowserParentProcess
    let parentSigningID: String
    let parentCDHash: Data
    let applicationPath: String
    let applicationSigningID: String
    let applicationCDHash: Data
    let applicationBundleID: String
}

/// Captures the native messaging host's actual browser caller once, then
/// requires that original process and code identity on every proof request.
/// The existing valid-signature/identifier policy is preserved; this does not
/// add a vendor trust claim or accept additional browsers.
public final class NativeBrowserParentIdentity {
    private let initial: BrowserParentEvidence
    private let observe: () -> BrowserParentEvidence?
    private let environment: VaultRuntimeEnvironment

    public static func capture(environment: VaultRuntimeEnvironment) -> NativeBrowserParentIdentity? {
        NativeBrowserParentIdentity(environment: environment) { readEvidence(environment: environment) }
    }

    init?(environment: VaultRuntimeEnvironment, observe: @escaping () -> BrowserParentEvidence?) {
        guard let evidence = observe(), Self.applicationIdentity(evidence, environment: environment) != nil else { return nil }
        initial = evidence
        self.observe = observe
        self.environment = environment
    }

    public func identityForProof() -> (program: String, identity: BrowserApplicationIdentity)? {
        guard let current = observe(), current == initial else { return nil }
        return Self.applicationIdentity(current, environment: environment)
    }

    static func applicationIdentity(_ evidence: BrowserParentEvidence, environment: VaultRuntimeEnvironment) -> (program: String, identity: BrowserApplicationIdentity)? {
        let host = evidence.host, parent = evidence.parent
        guard host.pid > 0, parent.pid > 1, host.parentPID == parent.pid, host.uid == parent.uid,
              (parent.seconds < host.seconds || parent.seconds == host.seconds && parent.microseconds <= host.microseconds),
              !host.path.isEmpty, !parent.path.isEmpty, !evidence.applicationPath.isEmpty,
              !evidence.parentCDHash.isEmpty, !evidence.applicationCDHash.isEmpty else { return nil }
        let id = evidence.applicationBundleID.lowercased()
        guard let program = acceptedProgram(evidence.parentSigningID, environment: environment),
              !evidence.applicationSigningID.isEmpty,
              !isHelper(evidence.applicationSigningID),
              let identity = BrowserApplicationIdentity(kind: "mac-bundle-id", value: id) else { return nil }
        return (program, identity)
    }

    private static func acceptedProgram(_ identifier: String, environment: VaultRuntimeEnvironment) -> String? {
        let applications = [
            "com.google.Chrome", "com.microsoft.edgemac", "org.chromium.Chromium",
            "com.brave.Browser", "com.operasoftware.Opera"
        ]
        for application in applications where identifier == application || identifier == application + ".helper" {
            return application == "com.microsoft.edgemac" ? "edge" : "chrome"
        }
        if environment == .development {
            if identifier == "com.google.chrome.for.testing" || identifier == "com.google.chrome.for.testing.helper" { return "chrome" }
            if identifier == "Chromium" || identifier == "Chromium Helper" { return "chrome" }
        }
        return nil
    }

    private static func isHelper(_ identifier: String) -> Bool {
        identifier.hasSuffix(".helper") || identifier == "Chromium Helper"
    }

    private static func process(_ pid: pid_t) -> BrowserParentProcess? {
        func bsd() -> proc_bsdinfo? {
            var value = proc_bsdinfo()
            let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout<proc_bsdinfo>.size))
            return count == MemoryLayout<proc_bsdinfo>.size ? value : nil
        }
        guard let before = bsd() else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, let after = bsd(),
              before.pbi_pid == after.pbi_pid, before.pbi_ppid == after.pbi_ppid, before.pbi_uid == after.pbi_uid,
              before.pbi_start_tvsec == after.pbi_start_tvsec, before.pbi_start_tvusec == after.pbi_start_tvusec else { return nil }
        return BrowserParentProcess(pid: pid, parentPID: pid_t(before.pbi_ppid), uid: before.pbi_uid,
                                    seconds: before.pbi_start_tvsec, microseconds: before.pbi_start_tvusec, path: String(cString: path))
    }

    private static func staticCode(_ url: URL, environment: VaultRuntimeEnvironment) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        if SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess { return code }
        guard environment == .development,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil) == errSecSuccess else { return nil }
        return code
    }

    private static func signingInformation(_ code: SecStaticCode) -> [String: Any]? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }

    private static func readEvidence(environment: VaultRuntimeEnvironment) -> BrowserParentEvidence? {
        guard getuid() == geteuid(), let host = process(getpid()), host.uid == getuid(),
              let parent = process(host.parentPID), parent.uid == host.uid else { return nil }
        var runningCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: parent.pid)] as CFDictionary, [], &runningCode) == errSecSuccess,
              let runningCode else { return nil }
        let runningValid = SecCodeCheckValidity(runningCode, [], nil)
        var runningStatic: SecStaticCode?
        guard runningValid == errSecSuccess || (environment == .development && SecCodeCheckValidity(runningCode, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil) == errSecSuccess),
              SecCodeCopyStaticCode(runningCode, [], &runningStatic) == errSecSuccess, let runningStatic,
              let runningInfo = signingInformation(runningStatic),
              let parentCode = staticCode(URL(fileURLWithPath: parent.path), environment: environment),
              let parentInfo = signingInformation(parentCode),
              let parentID = parentInfo[kSecCodeInfoIdentifier as String] as? String,
              let parentHash = parentInfo[kSecCodeInfoUnique as String] as? Data,
              runningInfo[kSecCodeInfoIdentifier as String] as? String == parentID,
              runningInfo[kSecCodeInfoUnique as String] as? Data == parentHash,
              acceptedProgram(parentID, environment: environment) != nil else { return nil }
        // A helper.app is not the native app target. Find its closest enclosing
        // non-helper application bundle. Its verified CFBundleIdentifier is the
        // actual app target; custom signing identifiers need not equal that ID.
        var cursor = URL(fileURLWithPath: parent.path).deletingLastPathComponent()
        var application: (URL, String, Data, String)?
        while cursor.path != "/" {
            if cursor.pathExtension == "app", let code = staticCode(cursor, environment: environment),
               let info = signingInformation(code),
               let identifier = info[kSecCodeInfoIdentifier as String] as? String,
               let hash = info[kSecCodeInfoUnique as String] as? Data,
               let plist = info[kSecCodeInfoPList as String] as? [String: Any],
               let bundleID = plist["CFBundleIdentifier"] as? String,
               !isHelper(identifier),
               BrowserApplicationIdentity(kind: "mac-bundle-id", value: bundleID.lowercased()) != nil {
                application = (cursor, identifier, hash, bundleID)
                break
            }
            cursor.deleteLastPathComponent()
        }
        guard let (app, appID, appHash, bundleID) = application,
              process(host.pid) == host, process(parent.pid) == parent else { return nil }
        return BrowserParentEvidence(host: host, parent: parent, parentSigningID: parentID, parentCDHash: parentHash,
                                     applicationPath: app.path, applicationSigningID: appID,
                                     applicationCDHash: appHash, applicationBundleID: bundleID)
    }
}
#endif
