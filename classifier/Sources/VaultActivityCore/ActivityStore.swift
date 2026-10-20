import Foundation
import VaultClassifierCore

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
    private let settingsEpoch = UUID().uuidString
    private var settingsRevision = 0
    private var settingsChangedAtMs = 0.0
    private let authorizationStartedAtMs: Double
    private var authorizationSettings: ActivitySettings?
    private struct BrowserGrant {
        let issuedAtMs: Double
        var endedAtMs: Double?
    }
    private var browserGrants: [Int: [ActivityCategory: BrowserGrant]] = [:]
    private var browserGrantOrder: [Int] = []
    private static let maximumBrowserGrantRevisions = 256
    private var settingsObservers: [UUID: @Sendable (ActivitySettingsSnapshot) -> Void] = [:]
    public private(set) var storageIssue: String?

    private static let settingsFileName = "settings.json"
    private static let webIconsFileName = "web-icons.json"
    private static let colorsFileName = "colors.json"
    private static let groupsFileName = "groups.json"
    private static let maxWebIcons = 500
    private static let factsFileName = "watched-facts.json"
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
        self.authorizationStartedAtMs = now().timeIntervalSince1970 * 1_000
    }

    // MARK: - Settings

    public func loadSettings() -> ActivitySettings {
        lock.lock(); defer { lock.unlock() }
        return loadSettingsLocked()
    }

    /// Atomically reads both the loaded settings and their in-process ordering
    /// metadata. Revision zero represents the loaded state before any commit.
    public func settingsSnapshot() -> ActivitySettingsSnapshot {
        lock.lock(); defer { lock.unlock() }
        let settings = loadSettingsLocked()
        if authorizationSettings == nil { initializeBrowserGrantsLocked(settings) }
        return snapshotLocked(settings)
    }

    /// Observers receive successful commits only. Delivery is outside the store
    /// lock, so callbacks may read or update the store. Concurrent commits can
    /// deliver out of order; consumers must compare epoch and revision.
    public func observeSettings(_ observer: @escaping @Sendable (ActivitySettingsSnapshot) -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        settingsObservers[token] = observer
        return token
    }

    /// Removal prevents capture by future commits; an already captured callback
    /// may still arrive and must be ignored by a retired consumer.
    public func removeSettingsObserver(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        settingsObservers.removeValue(forKey: token)
    }

    @discardableResult
    public func saveSettings(_ settings: ActivitySettings) -> ActivitySettingsSnapshot? {
        lock.lock()
        reconcileBrowserGrantsForCommitLocked(loadSettingsLocked())
        let committed = commitSettingsLocked(settings)
        let observers = committed == nil ? [] : Array(settingsObservers.values)
        lock.unlock()
        if let committed { observers.forEach { $0(committed) } }
        return committed
    }

    /// Atomic read-modify-write, with the exact successful commit returned and
    /// published rather than a later reread that could include another edit.
    @discardableResult
    public func updateSettings(_ mutate: (inout ActivitySettings) -> Void) -> ActivitySettingsSnapshot? {
        lock.lock()
        var settings = loadSettingsLocked()
        reconcileBrowserGrantsForCommitLocked(settings)
        mutate(&settings)
        let committed = commitSettingsLocked(settings)
        let observers = committed == nil ? [] : Array(settingsObservers.values)
        lock.unlock()
        if let committed { observers.forEach { $0(committed) } }
        return committed
    }

    private func snapshotLocked(_ settings: ActivitySettings) -> ActivitySettingsSnapshot {
        ActivitySettingsSnapshot(settings: settings, epoch: settingsEpoch,
                                 revision: settingsRevision, changedAtMs: settingsChangedAtMs)
    }

    private func commitSettingsLocked(_ settings: ActivitySettings) -> ActivitySettingsSnapshot? {
        guard settingsRevision < ActivitySettingsSnapshot.maxRevision else {
            storageIssue = "Activity settings revision limit reached; saved data is preserved."
            return nil
        }
        guard write(encode(settings), to: rootDirectory.appendingPathComponent(Self.settingsFileName)) else { return nil }
        settingsRevision += 1
        settingsChangedAtMs = now().timeIntervalSince1970 * 1_000
        for revision in browserGrantOrder {
            for category in ActivityWire.browserCategories where !settings.isEnabled(category) {
                if var grant = browserGrants[revision]?[category], grant.endedAtMs == nil {
                    grant.endedAtMs = settingsChangedAtMs
                    browserGrants[revision]?[category] = grant
                }
            }
        }
        authorizationSettings = settings
        addBrowserGrantsLocked(settings, revision: settingsRevision, issuedAtMs: settingsChangedAtMs)
        return snapshotLocked(settings)
    }

    private func initializeBrowserGrantsLocked(_ settings: ActivitySettings) {
        authorizationSettings = settings
        addBrowserGrantsLocked(settings, revision: settingsRevision, issuedAtMs: authorizationStartedAtMs)
    }

    private func reconcileBrowserGrantsForCommitLocked(_ settings: ActivitySettings) {
        if authorizationSettings == nil { initializeBrowserGrantsLocked(settings) }
        else if authorizationSettings != settings {
            // An external writer has no known OFF cutoff. Retire all prior
            // grants; only this store's next successful commit can grant again.
            browserGrants.removeAll(); browserGrantOrder.removeAll()
            authorizationSettings = settings
        }
    }

    private func addBrowserGrantsLocked(_ settings: ActivitySettings, revision: Int, issuedAtMs: Double) {
        var grants: [ActivityCategory: BrowserGrant] = [:]
        for category in ActivityWire.browserCategories where settings.isEnabled(category) {
            grants[category] = BrowserGrant(issuedAtMs: issuedAtMs)
        }
        browserGrants[revision] = grants
        browserGrantOrder.append(revision)
        while browserGrantOrder.count > Self.maximumBrowserGrantRevisions {
            browserGrants.removeValue(forKey: browserGrantOrder.removeFirst())
        }
    }

    /// Admits a contiguous observed browser interval under one native-known
    /// grant. Missing/malformed grants never fall back to the native API below.
    /// OFF seals old grants; its exact wall-time cutoff excludes later usage.
    public func recordBrowser(_ entry: ActivityBrowserRecord) -> ActivityBrowserRecordResult {
        lock.lock(); defer { lock.unlock() }
        let record = entry.record
        let startedAtMs = record.startedAt.timeIntervalSince1970 * 1_000
        guard ActivityWire.browserCategories.contains(record.category), !record.id.isEmpty, record.id.count <= 256,
              !record.key.isEmpty,
              let authorization = entry.authorization,
              UUID(uuidString: authorization.epoch) == UUID(uuidString: settingsEpoch),
              authorization.revision >= 0, authorization.revision <= ActivitySettingsSnapshot.maxRevision,
              let grant = browserGrants[authorization.revision]?[record.category],
              let endedAtMs = entry.observedEndedAtMs,
              startedAtMs.isFinite, endedAtMs.isFinite, startedAtMs >= 0,
              record.seconds.isFinite, record.seconds > 0, endedAtMs > startedAtMs,
              abs((endedAtMs - startedAtMs) - record.seconds * 1_000) <= 1,
              startedAtMs >= grant.issuedAtMs - 1,
              endedAtMs <= now().timeIntervalSince1970 * 1_000,
              authorizationSettings == loadSettingsLocked() else { return .rejected }
        let clippedStart = max(startedAtMs, grant.issuedAtMs)
        let clippedEnd = min(endedAtMs, grant.endedAtMs ?? endedAtMs)
        guard clippedEnd > clippedStart else { return .rejected }
        var clipped = record
        clipped.startedAt = Date(timeIntervalSince1970: clippedStart / 1_000)
        clipped.seconds = (clippedEnd - clippedStart) / 1_000
        let url = dayFileURL(category: clipped.category, day: dayString(for: clipped.startedAt))
        var records = readRecords(at: url)
        if let saved = records.first(where: { $0.id == clipped.id }) {
            // Compare the persisted representation: ISO8601 dates intentionally
            // omit fractions, including for the original Activity record format.
            return encode(saved) == encode(clipped) ? .alreadyStored : .rejected
        }
        records.append(clipped)
        return write(encode(records), to: url) ? .stored : .pending
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
        guard let icons = readValue([String: String].self, at: url) else { return [:] }
        return icons
    }

    // MARK: - Watched videos' authors and tags (owner 2026-09-29)

    /// Who made each watched video (with the author's icon) and its tags,
    /// saved when the video is watched: the classifier they come from forgets
    /// old videos. Tags missing then are picked up once, later, and never
    /// change after. Kept as long as the video's watched records (Watched's
    /// Keep). Local only.
    public func watchedFacts(for keys: [String]) -> [String: ActivityWatchedFacts] {
        lock.lock(); defer { lock.unlock() }
        let file = loadFactsLocked()
        var result: [String: ActivityWatchedFacts] = [:]
        for key in keys {
            guard let video = file.videos[key] else { continue }
            result[key] = ActivityWatchedFacts(author: video.author.flatMap { file.authors[$0] }, tags: video.tags)
        }
        return result
    }

    /// Saves what was found. A known author keeps its icon when the new
    /// lookup has none; a video's tags are saved once and then kept as they are.
    public func recordWatchedFacts(_ entries: [ActivityWatchedEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var file = loadFactsLocked()
        let before = file
        for entry in entries {
            var video = file.videos[entry.videoKey] ?? SavedVideo()
            if let id = entry.authorID, !id.isEmpty, let name = entry.authorName, !name.isEmpty {
                var author = file.authors[id] ?? ActivityAuthor(name: name, icon: nil)
                author.name = name
                if let icon = entry.authorIcon, icon.hasPrefix("data:image/"), icon.utf8.count <= Self.maxAuthorIconBytes {
                    author.icon = icon
                }
                file.authors[id] = author
                video.author = id
            }
            if video.tags == nil, let tags = entry.tags, !tags.isEmpty { video.tags = tags }
            if video.author != nil || video.tags != nil { file.videos[entry.videoKey] = video }
        }
        if file != before { write(encode(file), to: rootDirectory.appendingPathComponent(Self.factsFileName)) }
    }

    private struct SavedVideo: Codable, Equatable {
        var author: String?
        var tags: [ActivityTag]?
    }

    private struct FactsFile: Codable, Equatable {
        var videos: [String: SavedVideo] = [:]
        var authors: [String: ActivityAuthor] = [:]
    }

    private func loadFactsLocked() -> FactsFile {
        let url = rootDirectory.appendingPathComponent(Self.factsFileName)
        guard let file = readValue(FactsFile.self, at: url) else { return FactsFile() }
        return file
    }

    /// Drops the saved facts of videos no longer in the watched history (and
    /// authors no video names).
    private func pruneFactsLocked() {
        var file = loadFactsLocked()
        guard !file.videos.isEmpty else { return }
        var kept = Set<String>()
        for url in dayFiles(for: .contentWatched) {
            for record in readRecords(at: url) { kept.insert(record.key) }
        }
        let before = file
        file.videos = file.videos.filter { kept.contains($0.key) }
        let named = Set(file.videos.values.compactMap(\.author))
        file.authors = file.authors.filter { named.contains($0.key) }
        if file != before { write(encode(file), to: rootDirectory.appendingPathComponent(Self.factsFileName)) }
    }

    // MARK: - Colours (owner rule 2026-09-29)

    /// Every app and website has one permanent, unique colour index:
    /// "app|<bundle id>" / "web|<domain>" → index, assigned once (the next
    /// unused index, in the order given) and never reused or removed — not
    /// even when history is deleted. Returns the whole mapping.
    public func colorIndices(for ids: [String]) -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let url = rootDirectory.appendingPathComponent(Self.colorsFileName)
        var mapping = readValue([String: Int].self, at: url) ?? [:]
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
        return readValue([ActivityGroup].self, at: url) ?? []
    }

    /// Saves a group (new when its id is empty or unknown); returns its id. A
    /// merge group may not take another merge group's member unless `move`.
    public func saveGroup(_ group: ActivityGroup, move: Bool = false) -> Result<String, ActivityGroupRefusal> {
        lock.lock(); defer { lock.unlock() }
        switch ActivityGroups.saving(group, into: loadGroupsLocked(), move: move, newID: { UUID().uuidString }) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let saved):
            guard write(encode(saved.groups), to: rootDirectory.appendingPathComponent(Self.groupsFileName)) else { return .failure(.storageUnavailable) }
            return .success(saved.id)
        }
    }

    @discardableResult
    public func deleteGroup(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var groups = loadGroupsLocked()
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups.remove(at: index)
        return write(encode(groups), to: rootDirectory.appendingPathComponent(Self.groupsFileName))
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
        return write(encode(records), to: url)
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

    /// Sessions overlapping a range, clipped to that range, oldest-first.
    public func records(
        category: ActivityCategory,
        from start: Date,
        to end: Date
    ) -> [ActivityRecord] {
        guard start < end else { return [] }
        // A foreground session can begin on an earlier day and span midnight
        // (or several days). Its file is keyed by its original start date.
        return dayFiles(for: category)
            .filter { url in
                guard let day = dayDate(fromFileName: url.deletingPathExtension().lastPathComponent) else { return false }
                return day <= end
            }
            .flatMap { readRecords(at: $0) }
            .compactMap { record -> ActivityRecord? in
                let overlapStart = max(start, record.startedAt)
                let overlapEnd = min(end, record.startedAt.addingTimeInterval(record.seconds))
                guard overlapEnd > overlapStart else { return nil }
                var clipped = record
                clipped.startedAt = overlapStart
                clipped.seconds = overlapEnd.timeIntervalSince(overlapStart)
                return clipped
            }
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
            // Websites remain observed usage when Apps recording is off or has
            // gaps. Browser and site intervals describe the same elapsed time.
            mapRecords = ActivityDashboard.union(
                records(category: .appUsage, from: mapFrom, to: now)
                + records(category: .webVisit, from: mapFrom, to: now)
            )
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

    /// Content's year map (owner 2026-09-30): seconds of watched content per
    /// day over `days`, all of it or only the content carrying one of
    /// `tagIDs` (a tag and every tag under it) by its saved tags.
    public func contentHistory(tagIDs: Set<String>?, days: Int) -> ActivityItemHistory {
        let now = now()
        let from = calendar.date(byAdding: .day, value: -max(1, days), to: calendar.startOfDay(for: now)) ?? now
        var watched = records(category: .contentWatched, from: from, to: now)
        if let tagIDs {
            let facts = watchedFacts(for: Array(Set(watched.map(\.key))))
            watched = watched.filter { record in
                (facts[record.key]?.tags ?? []).contains { tagIDs.contains($0.id) }
            }
        }
        return ActivityDashboard.history(records: watched, days: days, now: now, calendar: calendar)
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
            watchedTimeline: ActivityDashboard.timeline(from: watched, rangeStartMs: startMs, rangeEndMs: endMs) { _ in 0 },
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
            let days = effective.effectiveRetentionDays(for: category)
            guard days > 0 else { continue }
            guard let cutoff = calendar.date(byAdding: .day, value: -days, to: today) else { continue }
            for url in dayFiles(for: category) {
                guard let day = dayDate(fromFileName: url.deletingPathExtension().lastPathComponent),
                      day < cutoff else { continue }
                guard (try? policy(for: url).checkDestination(url)) != nil else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
        pruneFactsLocked()
    }

    /// Removes every activity record and the whole `Activity` tree (settings are
    /// kept: turning recording off is a separate action from erasing history).
    public func deleteAllRecords() {
        lock.lock(); defer { lock.unlock() }
        for category in ActivityCategory.allCases {
            try? fileManager.removeItem(at: categoryDirectory(category))
        }
        try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(Self.webIconsFileName))
        try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(Self.factsFileName))
    }

    public func delete(category: ActivityCategory) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: categoryDirectory(category))
        if category == .webVisit {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(Self.webIconsFileName))
        }
        if category == .contentWatched {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(Self.factsFileName))
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
        guard let settings = readValue(ActivitySettings.self, at: url) else {
            return ActivitySettings()
        }
        return settings
    }

    private func readRecords(at url: URL) -> [ActivityRecord] {
        readValue([ActivityRecord].self, at: url) ?? []
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data()
    }

    private func policy(for url: URL) -> StorageSchemaPolicy {
        let name = url.deletingPathExtension().lastPathComponent
        let format = dayDate(fromFileName: name) == nil ? "activity." + name : "activity.records." + url.deletingLastPathComponent().lastPathComponent
        return StorageSchemaPolicy(format: format)
    }

    private func readValue<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let schema = policy(for: url)
            let payload = try schema.payload(from: data)
            let result = try Self.makeDecoder().decode(type, from: payload)
            // Wrap only after the compatible alpha payload was fully decoded.
            if payload == data { _ = write(payload, to: url) }
            return result
        } catch {
            storageIssue = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    private func write(_ data: Data, to url: URL) -> Bool {
        guard !data.isEmpty else { return false }
        do {
            try VaultPrivateFile.createDirectory(at: url.deletingLastPathComponent(), fileManager: fileManager)
            let schema = policy(for: url)
            try schema.checkDestination(url)
            try schema.wrap(data).write(to: url, options: .atomic)
            try? VaultPrivateFile.restrict(url, fileManager: fileManager)
            return true
        } catch {
            storageIssue = error.localizedDescription
            return false
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
