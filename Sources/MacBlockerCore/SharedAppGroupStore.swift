import Foundation

/// File-backed store inside the App Group container. This is the single bridge
/// between the main app (which runs the editor + JavaScript runtime) and the
/// Screen Time app extensions (which run under tight memory budgets and must
/// avoid JavaScript). The app writes; the extensions read.
public final class SharedAppGroupStore: @unchecked Sendable {
    public static let webStoreFileName = "web-store.json"
    public static let planFileName = "enforcement-plan.json"
    public static let snoozeRequestsFileName = "snooze-requests.json"
    public static let usageSnapshotFileName = "usage-snapshot.json"
    public static let groupTargetsFileName = "group-targets.json"

    public let baseDirectory: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "macosBlocker.SharedAppGroupStore")

    public init(baseDirectory: URL = AppGroup.baseDirectory()) {
        self.baseDirectory = baseDirectory
        print("[SharedAppGroupStore] init baseDirectory: \(baseDirectory.path)")
    }

    public func url(for fileName: String) -> URL {
        baseDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func ensureDirectory() {
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            print("[SharedAppGroupStore] ensureDirectory FAILED for \(baseDirectory.path): \(error)")
        }
    }

    // MARK: Raw bytes

    public func readData(_ fileName: String, silent: Bool = false) -> Data? {
        queue.sync {
            let target = url(for: fileName)
            do {
                let data = try Data(contentsOf: target)
                return data
            } catch {
                if !silent {
                    print("[SharedAppGroupStore] readData FAILED for \(target.path): \(error)")
                }
                return nil
            }
        }
    }

    public func writeData(_ data: Data, to fileName: String) {
        queue.sync {
            ensureDirectory()
            let target = url(for: fileName)
            do {
                try data.write(to: target, options: [.atomic])
            } catch {
                print("[SharedAppGroupStore] writeData FAILED for \(target.path): \(error)")
            }
        }
    }

    public func removeFile(_ fileName: String) {
        queue.sync { try? fileManager.removeItem(at: url(for: fileName)) }
    }

    // MARK: Codable convenience

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func readJSON<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        guard let data = readData(fileName) else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    public func writeJSON<T: Encodable>(_ value: T, to fileName: String) {
        guard let data = try? Self.encoder.encode(value) else { return }
        writeData(data, to: fileName)
    }

    // MARK: Enforcement plan

    public func loadEnforcementPlan() -> EnforcementPlan? {
        readJSON(EnforcementPlan.self, from: Self.planFileName)
    }

    public func saveEnforcementPlan(_ plan: EnforcementPlan) {
        writeJSON(plan, to: Self.planFileName)
    }

    // MARK: Snooze requests (written by the Shield Action extension)

    public func loadSnoozeRequests() -> [SnoozeRequest] {
        readJSON([SnoozeRequest].self, from: Self.snoozeRequestsFileName) ?? []
    }

    public func appendSnoozeRequest(_ request: SnoozeRequest) {
        var requests = loadSnoozeRequests()
        requests.append(request)
        writeJSON(requests, to: Self.snoozeRequestsFileName)
    }

    public func clearSnoozeRequests() {
        removeFile(Self.snoozeRequestsFileName)
    }

    // MARK: Usage snapshot (shared so extensions can honor active snoozes)

    public func loadUsageSnapshot() -> UsageSnapshot {
        readJSON(UsageSnapshot.self, from: Self.usageSnapshotFileName) ?? UsageSnapshot()
    }

    public func saveUsageSnapshot(_ snapshot: UsageSnapshot) {
        writeJSON(snapshot, to: Self.usageSnapshotFileName)
    }

    // MARK: Native group targets
    //
    // App/category targets cannot be expressed in the web editor, so they are
    // assigned natively (e.g. via the FamilyActivityPicker) and merged into the
    // enforcement plan, keyed by the web editor's group IDs.

    public func loadGroupTargets() -> [String: [BlockTarget]] {
        guard let data = readData(Self.groupTargetsFileName, silent: true) else { return [:] }
        return (try? Self.decoder.decode([String: [BlockTarget]].self, from: data)) ?? [:]
    }

    public func saveGroupTargets(_ targets: [String: [BlockTarget]]) {
        writeJSON(targets, to: Self.groupTargetsFileName)
    }

    /// Assigns (replacing) the native targets for one group.
    public func setTargets(_ targets: [BlockTarget], forGroupID groupID: String) {
        var all = loadGroupTargets()
        all[groupID] = targets
        saveGroupTargets(all)
    }
}
