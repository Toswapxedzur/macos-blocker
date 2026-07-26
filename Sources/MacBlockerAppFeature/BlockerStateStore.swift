import Foundation
import MacBlockerCore

public struct BlockerStateStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL = BlockerStateStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load() throws -> BlockerAppState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return BlockerAppState()
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BlockerAppState.self, from: data)
    }

    public func save(_ state: BlockerAppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(
                VaultRuntimeEnvironment.current.sharedStoreDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("state.json")
    }
}
