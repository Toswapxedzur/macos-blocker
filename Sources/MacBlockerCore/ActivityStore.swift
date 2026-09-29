import Foundation

/// The native store of record for the Activity log (see ACTIVITY-LOG.md §4).
/// One file per (category, local day) so per-category retention and deletes are
/// whole-file operations. Local-only; there is no network path out of here.
///
/// The store is the privacy backstop: `record` writes nothing for a disabled
/// category, whatever the feeder does.
public final class ActivityStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let now: () -> Date
    private let calendar: Calendar
    private let lock = NSLock()
    private let fileManager = FileManager.default

    private static let settingsFileName = "settings.json"
    private static let webIconsFileName = "web-icons.json"
    private static let colorsFileName = "colors.json"
    private static let groupsFileName = "groups.json"
    private static let maxWebIcons = 500
    private static let authorsFileName = "watched-authors.json"
    private static let maxAuthorIconBytes = 24_000
    private static let maxWebIconBytes = 24_000

    public init(
        directory: URL,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.rootDirectory = directory
        self.now = now
        self.calendar = calendar
    }

    /// The store under this environment's application-support tree
    /// (`~/Library/Application Support/macosBlocker[-Development]/Activity`).
    public static func standard(
        environment: VaultRuntimeEnvironment = .current,
        fileManager: FileManager = .default
    ) -> ActivityStore {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        let directory = support
            .appendingPathComponent(environment.sharedStoreDirectoryName, isDirectory: true)
            .appendingPathComponent("Activity", isDirectory: true)
        return ActivityStore(directory: directory)
    }

    // MARK: - Settings

    public func loadSettings() -> ActivitySettings {
        lock.lock(); defer { lock.unlock() }
        return loadSettingsLocked()
    }

    public func saveSettings(_ settings: ActivitySettings) {
        lock.lock(); defer { lock.unlock() }
        write(encode(settings), to: rootDirectory.appendingPathComponent(Self.settingsFileName))
    }

    /// Atomic read-modify-write of the settings, so a toggle from the dashboard
    /// cannot race the hub's own settings writes.
    public func updateSettings(_ mutate: (inout ActivitySettings) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var settings = loadSettingsLocked()
        mutate(&settings)
        write(encode(settings), to: rootDirectory.appendingPathComponent(Self.settingsFileName))
    }

    // MARK: - Website icons (favicons, supplied by the extension as data URIs)

    /// Deduped domain → data-URI favicon cache, kept out of the records so a
    /// favicon is stored once per domain, not on every visit. Local only.
    public func webIcons() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return loadWebIconsLocked()
    }

    public func mergeWebIcons(_ icons: [String: String]) {
        guard !icons.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var current = loadWebIconsLocked()
        for (domain, uri) in icons {
            guard !domain.isEmpty, uri.hasPrefix("data:image/"), uri.utf8.count <= Self.maxWebIconBytes else { continue }
            current[domain] = uri
        }
        // Over the cap, older icons go first (never the ones just added).
        for key in Array(current.keys) where current.count > Self.maxWebIcons && icons[key] == nil {
            current.removeValue(forKey: key)
        }
        write(encode(current), to: rootDirectory.appendingPathComponent(Self.webIconsFileName))
    }

    private func loadWebIconsLocked() -> [String: String] {
        let url = rootDirectory.appendingPathComponent(Self.webIconsFileName)
        guard let data = try? Data(contentsOf: url),
              let icons = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return icons
    }

    // MARK: - Watched videos' authors (owner 2026-09-29)

    /// Who made each watched video, with the author's icon, recorded when the
    /// video is watched (the classifier, where it comes from, forgets old
    /// videos). Watched key → author; one icon per author. Local only.
    public func watchedAuthors(for keys: [String]) -> [String: ActivityAuthor] {
        lock.lock(); defer { lock.unlock() }
        let file = loadAuthorsLocked()
        var result: [String: ActivityAuthor] = [:]
        for key in keys {
            if let id = file.videos[key], let author = file.authors[id] { result[key] = author }
        }
        return result
    }

    /// Records authors (a known author keeps its icon when a new one is missing).
    public func recordAuthors(_ entries: [ActivityAuthorEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var file = loadAuthorsLocked()
        var changed = false
        for entry in entries where !entry.authorID.isEmpty && !entry.name.isEmpty {
            var author = file.authors[entry.authorID] ?? ActivityAuthor(name: entry.name, icon: nil)
            author.name = entry.name
            if let icon = entry.icon, icon.hasPrefix("data:image/"), icon.utf8.count <= Self.maxAuthorIconBytes { author.icon = icon }
            if file.authors[entry.authorID] != author { file.authors[entry.authorID] = author; changed = true }
            if file.videos[entry.videoKey] != entry.authorID { file.videos[entry.videoKey] = entry.authorID; changed = true }
        }
        if changed { write(encode(file), to: rootDirectory.appendingPathComponent(Self.authorsFileName)) }
    }

    private struct AuthorsFile: Codable {
        var videos: [String: String] = [:]
        var authors: [String: ActivityAuthor] = [:]
    }

    private func loadAuthorsLocked() -> AuthorsFile {
        let url = rootDirectory.appendingPathComponent(Self.authorsFileName)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(AuthorsFile.self, from: data) else { return AuthorsFile() }
        return file
    }

    // MARK: - Colours (owner rule 2026-09-29)

    /// Every app and website has one permanent, unique colour index:
    /// "app|<bundle id>" / "web|<domain>" → index, assigned once (the next
    /// unused index, in the order given) and never reused or removed — not
    /// even when history is deleted. Returns the whole mapping.
    public func colorIndices(for ids: [String]) -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let url = rootDirectory.appendingPathComponent(Self.colorsFileName)
        var mapping = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url))) ?? [:]
        var next = (mapping.values.max() ?? -1) + 1
        var added = false
        for id in ids where mapping[id] == nil {
            mapping[id] = next
            next += 1
            added = true
        }
        if added { write(encode(mapping), to: url) }
        return mapping
    }

    /// The registry's colours for these app and website records and the
    /// groups (new keys are registered largest first, so a range's top items
    /// get the base colours; a group has a colour of its own too).
    private func colors(app: [ActivityRecord], web: [ActivityRecord]) -> (app: (String) -> Int, web: (String) -> Int, group: (String) -> Int, next: Int) {
        let rank = { (records: [ActivityRecord]) in ActivityDashboard.bars(from: records) { _, _ in 0 }.map(\.key) }
        let mapping = colorIndices(for: rank(app).map { "app|" + $0 } + rank(web).map { "web|" + $0 } + groups().map { "group|" + $0.id })
        let next = (mapping.values.max() ?? -1) + 1
        return ({ mapping["app|" + $0] ?? 0 }, { mapping["web|" + $0] ?? 0 }, { mapping["group|" + $0] ?? 0 }, next)
    }

    // MARK: - Groups (owner 2026-09-29)

    public func groups() -> [ActivityGroup] {
        lock.lock(); defer { lock.unlock() }
        return loadGroupsLocked()
    }

    private func loadGroupsLocked() -> [ActivityGroup] {
        let url = rootDirectory.appendingPathComponent(Self.groupsFileName)
        return (try? JSONDecoder().decode([ActivityGroup].self, from: Data(contentsOf: url))) ?? []
    }

    /// Saves a group (new when its id is empty or unknown); returns its id. A
    /// merge group may not take another merge group's member unless `move`.
    public func saveGroup(_ group: ActivityGroup, move: Bool = false) -> Result<String, ActivityGroupRefusal> {
        lock.lock(); defer { lock.unlock() }
        switch ActivityGroups.saving(group, into: loadGroupsLocked(), move: move, newID: { UUID().uuidString }) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let saved):
            write(encode(saved.groups), to: rootDirectory.appendingPathComponent(Self.groupsFileName))
            return .success(saved.id)
        }
    }

    @discardableResult
    public func deleteGroup(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var groups = loadGroupsLocked()
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups.remove(at: index)
        write(encode(groups), to: rootDirectory.appendingPathComponent(Self.groupsFileName))
        return true
    }

    /// Every app and website seen in the last `days` days, most used first —
    /// what a group can hold.
    public func knownItems(days: Int) -> [ActivityKnownItem] {
        let now = now()
        let from = calendar.date(byAdding: .day, value: -max(1, days), to: calendar.startOfDay(for: now)) ?? now
        func items(_ category: ActivityCategory, _ prefix: String) -> [ActivityKnownItem] {
            ActivityDashboard.bars(from: records(category: category, from: from, to: now)) { _, _ in 0 }
                .map { ActivityKnownItem(id: prefix + $0.key, label: $0.label, seconds: $0.seconds) }
        }
        return (items(.appUsage, "app|") + items(.webVisit, "web|")).sorted { $0.seconds > $1.seconds }
    }

    // MARK: - Recording

    /// Appends a record. No-op when the record's category is disabled (the
    /// privacy backstop) or its seconds are non-positive. Idempotent: a record
    /// whose `id` already exists in its day file is not duplicated.
    @discardableResult
    public func record(_ record: ActivityRecord, settings: ActivitySettings? = nil) -> Bool {
        guard record.seconds > 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        let effective = settings ?? loadSettingsLocked()
        guard effective.isEnabled(record.category) else { return false }

        let url = dayFileURL(category: record.category, day: dayString(for: record.startedAt))
        var records = readRecords(at: url)
        guard !records.contains(where: { $0.id == record.id }) else { return false }
        records.append(record)
        write(encode(records), to: url)
        return true
    }

    // MARK: - Aggregation (dashboard)

    /// Total seconds per key for a category between two instants (inclusive of
    /// the days they fall on), sorted largest-first — the pie slices.
    public func aggregate(
        category: ActivityCategory,
        from start: Date,
        to end: Date
    ) -> [ActivityAggregate] {
        lock.lock(); defer { lock.unlock() }
        var totals: [String: (label: String, seconds: Double)] = [:]
        for record in records(category: category, from: start, to: end) {
            let existing = totals[record.key]
            totals[record.key] = (record.label, (existing?.seconds ?? 0) + record.seconds)
        }
        return totals
            .map { ActivityAggregate(key: $0.key, label: $0.value.label, seconds: $0.value.seconds) }
            .sorted { $0.seconds > $1.seconds }
    }

    /// Raw records for a category over a range, oldest-first.
    public func records(
        category: ActivityCategory,
        from start: Date,
        to end: Date
    ) -> [ActivityRecord] {
        var all: [ActivityRecord] = []
        for day in dayStrings(from: start, to: end) {
            all.append(contentsOf: readRecords(at: dayFileURL(category: category, day: day)))
        }
        return all
            .filter { $0.startedAt >= start && $0.startedAt <= end }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// What the Details panel shows: all usage, one app or website, or a group.
    public enum DetailPick: Equatable, Sendable {
        case all
        case item(ActivityCategory, String)
        case group(String)
    }

    /// The Details panel's data: the pick's per-day map over `mapDays`, and the
    /// last `barDays` days of usage — all usage, or only a group's members when
    /// a group is picked. A group's time is its members' time with overlaps
    /// counted once (a browser and a site inside it, two members at once).
    public func detail(pick: DetailPick, mapDays: Int, barDays: Int) -> ActivityDetail {
        let now = now()
        func since(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
        }
        // A day before the first day, so a session running into it is clipped in.
        let mapFrom = since(max(1, mapDays))
        let barsFrom = since(max(1, barDays))
        var members: Set<String>? = nil
        let mapRecords: [ActivityRecord]
        switch pick {
        case .all:
            mapRecords = records(category: .appUsage, from: mapFrom, to: now)
        case .item(let category, let key):
            mapRecords = records(category: category, from: mapFrom, to: now).filter { $0.key == key }
        case .group(let id):
            let group = groups().first { $0.id == id }
            let set = Set(group?.members ?? [])
            members = set
            mapRecords = ActivityDashboard.union(
                records(category: .appUsage, from: mapFrom, to: now).filter { set.contains("app|" + $0.key) }
                + records(category: .webVisit, from: mapFrom, to: now).filter { set.contains("web|" + $0.key) }
            )
        }
        var app = records(category: .appUsage, from: barsFrom, to: now)
        var web = records(category: .webVisit, from: barsFrom, to: now)
        if let members {
            app = app.filter { members.contains("app|" + $0.key) }
            web = web.filter { members.contains("web|" + $0.key) }
        }
        let color = colors(app: app, web: web)
        return ActivityDetail(
            map: ActivityDashboard.history(records: mapRecords, days: mapDays, now: now, calendar: calendar),
            days: ActivityDashboard.dayUsage(
                app: app, web: web, days: barDays, now: now, calendar: calendar,
                appColor: color.app, webColor: color.web
            )
        )
    }

    /// The render-ready dashboard snapshot for a range (bars + timeline + the
    /// watched-content bars + the current settings). Reads app-usage / web-visit /
    /// content-watched records for the range and builds geometry via
    /// `ActivityDashboard`.
    public func dashboardSnapshot(from start: Date, to end: Date) -> ActivityDashboardSnapshot {
        let startMs = start.timeIntervalSince1970 * 1000
        let endMs = end.timeIntervalSince1970 * 1000
        let app = records(category: .appUsage, from: start, to: end)
        let web = records(category: .webVisit, from: start, to: end)
        let watched = records(category: .contentWatched, from: start, to: end)
        // Apps and sites take their permanent colours; watched videos take
        // indices after the registry's, so they never collide with one.
        let color = colors(app: app, web: web)
        let appLens = ActivityDashboard.lens(from: app, rangeStartMs: startMs, rangeEndMs: endMs, colorFor: color.app)
        let webLens = ActivityDashboard.lens(from: web, rangeStartMs: startMs, rangeEndMs: endMs, colorFor: color.web)
        return ActivityDashboardSnapshot(
            rangeStartMs: startMs,
            rangeEndMs: endMs,
            app: appLens,
            web: webLens,
            watched: ActivityDashboard.bars(from: watched) { _, rank in color.next + rank },
            settings: ActivityDashboard.settingsView(loadSettings()),
            groups: groups().map { ActivityGroupView(id: $0.id, name: $0.name, merge: $0.merge, members: $0.members, colorIndex: color.group($0.id)) }
        )
    }

    // MARK: - Retention / deletion

    /// Deletes day files older than each category's retention window. A window of
    /// `0` keeps everything. Call on a schedule and at launch.
    public func prune(settings: ActivitySettings? = nil) {
        lock.lock(); defer { lock.unlock() }
        let effective = settings ?? loadSettingsLocked()
        let today = calendar.startOfDay(for: now())
        for category in ActivityCategory.allCases {
            let days = effective.settings(for: category).retentionDays
            guard days > 0 else { continue }
            guard let cutoff = calendar.date(byAdding: .day, value: -days, to: today) else { continue }
            for url in dayFiles(for: category) {
                guard let day = dayDate(fromFileName: url.deletingPathExtension().lastPathComponent),
                      day < cutoff else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Removes every activity record and the whole `Activity` tree (settings are
    /// kept: turning recording off is a separate action from erasing history).
    public func deleteAllRecords() {
        lock.lock(); defer { lock.unlock() }
        for category in ActivityCategory.allCases {
            try? fileManager.removeItem(at: categoryDirectory(category))
        }
        try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(Self.webIconsFileName))
        try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(Self.authorsFileName))
    }

    public func delete(category: ActivityCategory) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: categoryDirectory(category))
        if category == .webVisit {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(Self.webIconsFileName))
        }
        if category == .contentWatched {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(Self.authorsFileName))
        }
    }

    /// Deletes records whose start falls in `[start, end]`. Whole day files inside
    /// the range are removed; the boundary days are filtered in place.
    public func delete(from start: Date, to end: Date) {
        lock.lock(); defer { lock.unlock() }
        for category in ActivityCategory.allCases {
            for day in dayStrings(from: start, to: end) {
                let url = dayFileURL(category: category, day: day)
                let kept = readRecords(at: url).filter { $0.startedAt < start || $0.startedAt > end }
                if kept.isEmpty {
                    try? fileManager.removeItem(at: url)
                } else {
                    write(encode(kept), to: url)
                }
            }
        }
    }

    // MARK: - Paths

    private func categoryDirectory(_ category: ActivityCategory) -> URL {
        rootDirectory.appendingPathComponent(category.rawValue, isDirectory: true)
    }

    private func dayFileURL(category: ActivityCategory, day: String) -> URL {
        categoryDirectory(category).appendingPathComponent("\(day).json", isDirectory: false)
    }

    private func dayFiles(for category: ActivityCategory) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: categoryDirectory(category), includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: - IO

    /// Matches `encode`: dates are ISO8601, so the reader must decode them the
    /// same way (the default strategy expects a number and would fail every read).
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func loadSettingsLocked() -> ActivitySettings {
        let url = rootDirectory.appendingPathComponent(Self.settingsFileName)
        guard let data = try? Data(contentsOf: url),
              let settings = try? Self.makeDecoder().decode(ActivitySettings.self, from: data) else {
            return ActivitySettings()
        }
        return settings
    }

    private func readRecords(at url: URL) -> [ActivityRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.makeDecoder().decode([ActivityRecord].self, from: data)) ?? []
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data()
    }

    private func write(_ data: Data, to url: URL) {
        guard !data.isEmpty else { return }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Best-effort background persistence; a lost record is preferable to a crash.
        }
    }

    // MARK: - Day math

    private lazy var dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func dayString(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private func dayDate(fromFileName name: String) -> Date? {
        dayFormatter.date(from: name)
    }

    private func dayStrings(from start: Date, to end: Date) -> [String] {
        guard start <= end else { return [] }
        var days: [String] = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while cursor <= last {
            days.append(dayString(for: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }
}
