import Foundation

public struct SeedBackupManifest: Codable, Equatable, Sendable {
    public var packageID: String
    public var checksum: String
    public var createdAt: Date

    public init(packageID: String, checksum: String, createdAt: Date = .now) {
        self.packageID = packageID
        self.checksum = checksum
        self.createdAt = createdAt
    }
}

public struct LocalSeedBackup: Sendable {
    public init() {}

    /// Stores the current package plus the three most recent other packages. The caller chooses
    /// the directory (for example, a Mac mini backup folder); no network transport is involved.
    @discardableResult
    public func backup(_ package: VerifiedSeedPackage, in directory: URL, retainingAtMost count: Int = 4) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(package.package.packageID)-\(package.checksum.prefix(12))"
        let destination = directory.appendingPathComponent(name, isDirectory: true)
        if !fileManager.fileExists(atPath: destination.path) {
            let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try package.rawData.write(to: staging.appendingPathComponent("seed-package.json"), options: .atomic)
            let manifest = SeedBackupManifest(packageID: package.package.packageID, checksum: package.checksum)
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            try fileManager.moveItem(at: staging, to: destination)
        }
        let folders = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.hasDirectoryPath }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        for stale in folders.dropFirst(max(1, count)) { try fileManager.removeItem(at: stale) }
        return destination
    }
}
