import Foundation
#if os(Windows)
import CVaultWindows
#endif

/// Native privacy boundary for app-owned files. Windows uses a protected
/// current-user/SYSTEM DACL; macOS retains its existing 0700/0600 permissions.
public enum VaultPrivateFile {
    public static func createDirectory(at url: URL, fileManager: FileManager = .default) throws {
        #if os(Windows)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try restrict(url, directory: true, fileManager: fileManager)
        #else
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #endif
    }

    public static func restrict(_ url: URL, directory: Bool = false, fileManager: FileManager = .default) throws {
        #if os(Windows)
        let result = url.path.withCString { vault_windows_restrict_path($0) }
        guard result == 0 else { throw NSError(domain: "VaultWindowsPrivateFile", code: Int(result)) }
        #else
        try fileManager.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
        #endif
    }

    #if os(Windows)
    public static func protectedData(_ data: Data, decrypt: Bool = false) throws -> Data {
        var pointer: UnsafeMutablePointer<UInt8>?
        var count = 0
        let result = data.withUnsafeBytes { source in
            vault_windows_protect(source.bindMemory(to: UInt8.self).baseAddress, source.count, &pointer, &count, decrypt ? 1 : 0)
        }
        guard result == 0, let pointer else { throw NSError(domain: "VaultWindowsProtectedData", code: Int(result)) }
        defer { vault_windows_free(pointer) }
        return Data(bytes: pointer, count: count)
    }

    public static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = vault_windows_random(&bytes, bytes.count)
        guard result == 0 else { throw NSError(domain: "VaultWindowsRandom", code: Int(result)) }
        return Data(bytes)
    }

    public static func iconJPEG(_ data: Data) -> Data? {
        var pointer: UnsafeMutablePointer<UInt8>?
        var count = 0
        let result = data.withUnsafeBytes { source in
            vault_windows_image_jpeg(source.bindMemory(to: UInt8.self).baseAddress, source.count, &pointer, &count)
        }
        guard result == 0, let pointer else { return nil }
        defer { vault_windows_free(pointer) }
        return Data(bytes: pointer, count: count)
    }
    #endif
}
