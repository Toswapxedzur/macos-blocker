import Foundation

/// The user-granted folder for custom-rule file I/O on macOS. Mirrors the browser
/// extension's "choose a folder" grant: nothing is available until the user picks
/// a folder, and revoking disconnects it (file operations then fail until a new
/// folder is chosen). The grant is persisted as a security-scoped bookmark so it
/// survives relaunches and is correct for a future sandboxed build.
///
/// The AppKit folder picker lives in the WebUI layer (`BlockerWebView`); this type
/// only stores, resolves, clears, and reports the grant, so it stays Foundation-only
/// and usable from both the WebView and the enforcement bridge.
public enum LocalFolderGrant {
    /// Keyed by environment so development and production keep separate grants,
    /// matching the rest of the app's dev/prod state separation.
    private static var defaultsKey: String {
        "LocalFolderGrant.bookmark.\(VaultRuntimeEnvironment.current.localFilesDirectoryName)"
    }

    /// Persist a security-scoped bookmark for the user-picked folder.
    public static func store(bookmark: Data) {
        UserDefaults.standard.set(bookmark, forKey: defaultsKey)
    }

    /// Forget the grant. Custom-rule file I/O then fails until a folder is chosen.
    public static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Whether a folder is currently granted (a bookmark is stored).
    public static var isConnected: Bool {
        UserDefaults.standard.data(forKey: defaultsKey) != nil
    }

    /// Resolve the granted folder URL. Returns nil when no folder is granted or the
    /// bookmark can no longer be resolved (the folder was moved or deleted), in which
    /// case the stale grant is cleared. The caller must balance
    /// `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`
    /// around any file access.
    public static func resolvedFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            clear()
            return nil
        }
        return url
    }

    /// Display name of the granted folder, or "" when none is granted.
    public static var folderName: String {
        resolvedFolderURL()?.lastPathComponent ?? ""
    }
}
